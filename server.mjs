// RedactProof bridge - Phase 1 prototype.
// Localhost HTTP wrapper around gliner running on native onnxruntime-node.
// Same model + same labels the browser ships, ~50-70x faster on Snapdragon.

import { createServer } from 'node:http';
import { writeFileSync, mkdirSync, existsSync, readFileSync, appendFileSync, statSync, renameSync } from 'node:fs';
import { homedir, totalmem, cpus, release, platform as osPlatform } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';
import { Gliner } from 'gliner/node';
import { env } from '@xenova/transformers';

// File logging - the installer launches us with stdout/stderr discarded.
// Mirror everything to a log file users can share for support.
const LOG_DIR = join(homedir(), '.redactproof');
const LOG_PATH = join(LOG_DIR, 'bridge.log');
const LOG_MAX_BYTES = 1_048_576; // 1MB - rotate to bridge.log.1 on overflow
try { if (!existsSync(LOG_DIR)) mkdirSync(LOG_DIR, { recursive: true }); } catch {}
function appendLog(level, args) {
  try {
    const line = `${new Date().toISOString()} [${level}] ${args
      .map(a => (typeof a === 'string' ? a : (() => { try { return JSON.stringify(a); } catch { return String(a); } })()))
      .join(' ')}\n`;
    try {
      const stat = statSync(LOG_PATH);
      if (stat.size > LOG_MAX_BYTES) {
        try { renameSync(LOG_PATH, `${LOG_PATH}.1`); } catch {}
      }
    } catch {}
    appendFileSync(LOG_PATH, line);
  } catch {}
}
const _origLog = console.log.bind(console);
const _origErr = console.error.bind(console);
console.log = (...args) => { _origLog(...args); appendLog('info', args); };
console.error = (...args) => { _origErr(...args); appendLog('error', args); };
// Flipped true once the server is listening + discoverable. A rejection before
// that point (e.g. model load) is fatal and must exit rather than leave a
// half-initialised zombie holding the port; after it, a stray rejection from a
// single bad request should not take the whole bridge down.
let serverReady = false;
process.on('uncaughtException', (err) => {
  appendLog('fatal', ['uncaughtException', err?.message ?? String(err)]);
  process.exit(1);
});
process.on('unhandledRejection', (err) => {
  appendLog('fatal', ['unhandledRejection', err?.message ?? String(err)]);
  if (!serverReady) process.exit(1);
});

// model-config.json sits next to server.mjs and can override host/repo
// without env vars. Used by the variant-test workflow (swap-model.ps1).
const __dir = dirname(fileURLToPath(import.meta.url));
let fileConfig = {};
try {
  const p = join(__dir, 'model-config.json');
  if (existsSync(p)) fileConfig = JSON.parse(readFileSync(p, 'utf8').replace(/^﻿/, ''));
} catch {}

const useRemote = !!(process.env.RP_MODEL_HOST || fileConfig.host);
const MAX_WIDTH = 12;
console.log(`[bridge] mode=${useRemote ? 'remote' : 'local'}`);

let tokenizerPath;
if (useRemote) {
  const MODEL_REMOTE_HOST = process.env.RP_MODEL_HOST ?? fileConfig.host;
  const MODEL_REPO = process.env.RP_MODEL_REPO ?? fileConfig.repo ?? 'gliner_medium-v2.1';
  env.remoteHost = MODEL_REMOTE_HOST;
  env.remotePathTemplate = '{model}/resolve/{revision}';
  env.allowRemoteModels = true;
  env.allowLocalModels = false;
  tokenizerPath = MODEL_REPO;
} else {
  const localTokenizerDir = join(__dir, 'tokenizer');
  if (!existsSync(localTokenizerDir)) {
    console.error('[bridge] tokenizer missing - reinstall the accelerator');
    process.exit(1);
  }
  env.localModelPath = __dir;
  env.allowLocalModels = true;
  tokenizerPath = 'tokenizer';
}
env.useFSCache = false;
env.useBrowserCache = false;

let gliner;
try {
  gliner = new Gliner({
    tokenizerPath,
    onnxSettings: {
      modelPath: process.env.RP_MODEL_PATH ?? join(__dir, 'core.bin'),
      executionProvider: 'cpu',
    },
    maxWidth: MAX_WIDTH,
    modelType: 'span-level',
    transformersSettings: {
      allowLocalModels: !useRemote,
    },
  });

  console.log('[bridge] initialising...');
  const t0 = Date.now();
  await gliner.initialize();
  console.log(`[bridge] initialised in ${Date.now() - t0}ms`);
} catch (err) {
  // A missing/corrupt core.bin or tokenizer throws here. Without this guard the
  // rejection escaped top-level await, hit unhandledRejection (which did not
  // exit), and left a zombie that 500s every /infer. Fail loudly instead.
  console.error(`[bridge] FATAL: model initialisation failed - check core.bin and the tokenizer dir: ${err?.message ?? String(err)}`);
  process.exit(1);
}

// Startup diagnostics - useful for support without exposing PII or model identity
function getCPU() {
  if (process.platform === 'darwin') {
    try { return execSync('sysctl -n machdep.cpu.brand_string', { encoding: 'utf8', timeout: 1000 }).trim(); } catch {}
  }
  return cpus()[0]?.model ?? process.arch;
}
function getOSVersion() {
  if (process.platform === 'darwin') {
    try { return `macOS ${execSync('sw_vers -productVersion', { encoding: 'utf8', timeout: 1000 }).trim()}`; } catch {}
    return 'macOS (unknown version)';
  }
  if (process.platform === 'win32') { return `Windows ${release()}`; }
  return `${osPlatform()} ${release()}`;
}
const chip  = getCPU();
const ramGB = Math.round(totalmem() / 1_073_741_824);
const osVer = getOSVersion();
let modelMB = '?';
try { modelMB = (statSync(join(__dir, 'core.bin')).size / 1_048_576).toFixed(1); } catch {}
console.log(`[bridge] system: ${chip} | ${osVer} | ${ramGB}GB RAM`);
console.log(`[bridge] runtime: node ${process.version} | core.bin ${modelMB}MB`);

// Origins allowed to call the bridge. A wildcard let any site the user visited
// probe /health (fingerprint that the paid Accelerator is installed) and drive
// /infer (burn CPU). Only the RedactProof app origins and localhost dev are
// permitted now. If a browser extension is ever built to call the bridge
// directly, add its chrome-extension:// origin here.
const ALLOWED_ORIGINS = new Set([
  'https://app.redactproof.com',
  'https://staging.redactproof.com',
]);
function originAllowed(origin) {
  if (ALLOWED_ORIGINS.has(origin)) return true;
  try {
    const h = new URL(origin).hostname;
    return h === 'localhost' || h === '127.0.0.1' || h === '[::1]';
  } catch { return false; }
}

const server = createServer(async (req, res) => {
  // No Origin header = not a browser cross-origin call (the threat model) - let
  // it through without CORS headers. A non-allowlisted Origin is refused before
  // any work, defeating both /health fingerprinting and /infer CPU-DoS; the
  // browser also can't read a response that carries no ACAO header.
  const origin = req.headers.origin;
  if (origin && originAllowed(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    res.setHeader('Access-Control-Allow-Private-Network', 'true');
  } else if (origin) {
    return res.writeHead(403, { 'Content-Type': 'application/json' })
      .end(JSON.stringify({ error: 'origin not allowed' }));
  }
  if (req.method === 'OPTIONS') return res.writeHead(204).end();

  if (req.url === '/health') {
    return res.writeHead(200, { 'Content-Type': 'application/json' })
      .end(JSON.stringify({ ok: true, app: 'redactproof-bridge', version: '0.1.1' }));
  }

  if ((req.url === '/infer' || req.url === '/infer/batch') && req.method === 'POST') {
    const isBatch = req.url === '/infer/batch';
    // Buffer as Buffers + a single concat (string += reallocates the growing
    // string on every chunk) and cap the total so a cross-origin POST can't
    // exhaust memory and crash the bridge.
    const MAX_BODY_BYTES = 4 * 1024 * 1024;
    const chunks = [];
    let bodyLen = 0;
    let tooLarge = false;
    req.on('error', (err) => {
      // Client disconnect mid-stream. Without this handler the stream 'error'
      // became an uncaughtException, which exits the process - killing the
      // bridge on every aborted request (e.g. the extension toggling off).
      console.error(`[bridge] request stream error: ${err?.message ?? String(err)}`);
    });
    req.on('data', c => {
      if (tooLarge) return;
      bodyLen += c.length;
      if (bodyLen > MAX_BODY_BYTES) {
        tooLarge = true;
        res.writeHead(413, { 'Content-Type': 'application/json' })
          .end(JSON.stringify({ error: 'request body too large' }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', async () => {
      if (tooLarge || req.destroyed) return;
      try {
        const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        const { labels } = parsed;
        const texts = isBatch ? parsed.texts : [parsed.text];
        if (!Array.isArray(texts) || !texts.every(t => typeof t === 'string') || !Array.isArray(labels)) {
          return res.writeHead(400, { 'Content-Type': 'application/json' })
            .end(JSON.stringify({ error: 'texts/text + labels required' }));
        }
        // Bound the work a single request can demand. Inference cost scales with
        // texts x labels; the body cap already bounds total characters.
        const MAX_TEXTS = 512, MAX_LABELS = 64;
        if (texts.length > MAX_TEXTS) {
          return res.writeHead(400, { 'Content-Type': 'application/json' })
            .end(JSON.stringify({ error: `too many texts (max ${MAX_TEXTS})` }));
        }
        if (labels.length > MAX_LABELS || !labels.every(l => typeof l === 'string' && l.length <= 128)) {
          return res.writeHead(400, { 'Content-Type': 'application/json' })
            .end(JSON.stringify({ error: `invalid labels (max ${MAX_LABELS}, each <=128 chars)` }));
        }
        let threshold = Number(parsed.threshold ?? 0.5);
        if (!Number.isFinite(threshold)) threshold = 0.5;
        threshold = Math.min(Math.max(threshold, 0), 1);
        const t = Date.now();
        const results = await gliner.inference({
          texts,
          entities: labels,
          threshold,
          flatNer: true,
        });
        const inferenceMs = Date.now() - t;
        const mapped = results.map((entityList, i) => (entityList || []).map(e => ({
          text: e.text ?? texts[i].substring(e.start ?? 0, e.end ?? 0),
          label: e.label ?? '',
          start: e.start ?? 0,
          end: e.end ?? 0,
          score: e.score ?? 0,
        })));
        console.log(`[bridge] ${isBatch ? 'batch' : 'single'} texts=${texts.length} totalChars=${texts.reduce((a, t) => a + t.length, 0)} entities=${mapped.reduce((a, e) => a + e.length, 0)} ms=${inferenceMs}`);
        // Client may have disconnected during inference; writing to a dead
        // socket throws -> uncaughtException -> exit. Bail if it's gone.
        if (res.writableEnded || res.destroyed) return;
        res.writeHead(200, { 'Content-Type': 'application/json' })
          .end(JSON.stringify(isBatch ? { batches: mapped, inferenceMs } : { entities: mapped[0], inferenceMs }));
      } catch (err) {
        console.error(`[bridge] ${isBatch ? 'batch' : 'single'} inference failed: ${err?.message ?? String(err)}`);
        if (res.writableEnded || res.destroyed) return;
        // Generic message only - err.message can carry internal detail. The full
        // error is in the bridge log above for debugging.
        try {
          res.writeHead(500, { 'Content-Type': 'application/json' })
            .end(JSON.stringify({ error: 'inference failed' }));
        } catch {}
      }
    });
    return;
  }

  res.writeHead(404).end(JSON.stringify({ error: 'not found' }));
});

const PORT_RANGE = [47821, 47822, 47823, 47824, 47825];
const explicitPort = process.env.PORT ? Number(process.env.PORT) : null;
const candidates = explicitPort !== null ? [explicitPort] : PORT_RANGE;

function tryListen(ports, idx = 0) {
  if (idx >= ports.length) {
    console.error(`[bridge] no free port in range ${ports.join(',')}`);
    process.exit(1);
  }
  const p = ports[idx];
  server.once('error', (err) => {
    if (err.code === 'EADDRINUSE') {
      console.log(`[bridge] port ${p} in use, trying next`);
      tryListen(ports, idx + 1);
    } else {
      console.error(`[bridge] listen error: ${err?.message ?? String(err)}`);
      process.exit(1);
    }
  });
  server.listen(p, '127.0.0.1', () => {
    const actual = server.address().port;
    const dir = join(homedir(), '.redactproof');
    try {
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, 'accelerator.json'), JSON.stringify({ port: actual, version: '0.1.1', pid: process.pid }));
    } catch (err) {
      // The app discovers us by reading this file; if it can't be written the
      // bridge is unusable. Exit loudly rather than run undiscoverable.
      console.error(`[bridge] FATAL: cannot write discovery file - check ~/.redactproof permissions: ${err?.message ?? String(err)}`);
      process.exit(1);
    }
    try { writeFileSync(new URL('./bridge.pid', import.meta.url), String(process.pid)); } catch {}
    serverReady = true;
    console.log(`[bridge] listening on http://127.0.0.1:${actual}`);
  });
}

tryListen(candidates);