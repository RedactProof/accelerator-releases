// RedactProof bridge - Phase 1 prototype.
// Localhost HTTP wrapper around gliner running on native onnxruntime-node.
// Same model + same labels the browser ships, ~50-70x faster on Snapdragon.

import { createServer } from 'node:http';
import { writeFileSync, mkdirSync, existsSync, readFileSync, appendFileSync, statSync, renameSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Gliner } from 'gliner/node';
import { env } from '@xenova/transformers';

// File logging - the installer launches us via wscript.exe with stdout/stderr
// discarded, so console output goes nowhere. Mirror everything to a log file
// users can tail to debug bridge crashes / 500s.
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
process.on('uncaughtException', (err) => {
  appendLog('fatal', ['uncaughtException', err?.stack ?? String(err)]);
  process.exit(1);
});
process.on('unhandledRejection', (err) => {
  appendLog('fatal', ['unhandledRejection', err?.stack ?? String(err)]);
});

// model-config.json sits next to server.mjs and can override host/repo
// without env vars. Used by the variant-test workflow (swap-model.ps1).
const __dir = dirname(fileURLToPath(import.meta.url));
let fileConfig = {};
try {
  const p = join(__dir, 'model-config.json');
  if (existsSync(p)) fileConfig = JSON.parse(readFileSync(p, 'utf8').replace(/^﻿/, ''));
} catch {}

// Tokenizer source: by default load from a bundled local dir that is
// version-locked to core.bin. Hitting HuggingFace live (the previous
// behaviour) was: (a) observable in network traffic, leaking the model
// identity against the project's no-model-names rule; (b) brittle - a
// downstream tokenizer update added a vocab token the shipped core.bin's
// embedding matrix couldn't index, producing 500s on every /infer; (c) it
// made the bridge unusable offline. Remote mode is preserved as an opt-in
// for the swap-model variant-test workflow.
const TOKENIZER_DIR_NAME = 'tokenizer';
const useRemote = !!(process.env.RP_MODEL_HOST || fileConfig.host);
const VARIANT_LABEL = fileConfig.label ?? (useRemote ? 'remote' : 'default');
const MAX_WIDTH = 12;
console.log(`[bridge] variant: ${VARIANT_LABEL} mode=${useRemote ? 'remote' : 'local'}`);

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
  const localTokenizerDir = join(__dir, TOKENIZER_DIR_NAME);
  if (!existsSync(localTokenizerDir)) {
    console.error(`[bridge] tokenizer dir missing at ${localTokenizerDir}`);
    console.error('[bridge] reinstall the accelerator, or run tools/bridge/scripts/download-tokenizer.ps1 in dev');
    process.exit(1);
  }
  // transformers resolves localModelPath + tokenizerPath, so localModelPath
  // points at __dir and tokenizerPath is the subdir name.
  env.localModelPath = __dir;
  env.allowLocalModels = true;
  // Leave allowRemoteModels at its default (true). Setting it false here
  // tripped "both local and remote models are disabled" at runtime inside
  // @xenova/transformers' hub.js even though allowLocalModels was true -
  // some code paths read the flags before the local-first check kicks in.
  // Local files satisfy the request first, so remote is never actually hit.
  tokenizerPath = TOKENIZER_DIR_NAME;
}
env.useFSCache = false;
env.useBrowserCache = false;

const gliner = new Gliner({
  tokenizerPath,
  onnxSettings: {
    modelPath: process.env.RP_MODEL_PATH ?? './core.bin',
    executionProvider: 'cpu',
  },
  maxWidth: MAX_WIDTH,
  modelType: 'span-level',
  // gliner's constructor unconditionally writes env.allowLocalModels from this
  // option (default false), clobbering our env mutation above. Without it, a
  // local-mode bridge silently falls through to HuggingFace at runtime.
  transformersSettings: {
    allowLocalModels: !useRemote,
  },
});

console.log('[bridge] initialising...');
const t0 = Date.now();
await gliner.initialize();
console.log(`[bridge] initialised in ${Date.now() - t0}ms`);

const server = createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Private-Network', 'true');
  if (req.method === 'OPTIONS') return res.writeHead(204).end();

  if (req.url === '/health') {
    return res.writeHead(200, { 'Content-Type': 'application/json' })
      .end(JSON.stringify({ ok: true, app: 'redactproof-bridge', version: '0.0.1' }));
  }

  if ((req.url === '/infer' || req.url === '/infer/batch') && req.method === 'POST') {
    const isBatch = req.url === '/infer/batch';
    let body = '';
    req.on('data', c => (body += c));
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body);
        const { labels, threshold = 0.5 } = parsed;
        const texts = isBatch ? parsed.texts : [parsed.text];
        if (!Array.isArray(texts) || !texts.every(t => typeof t === 'string') || !Array.isArray(labels)) {
          return res.writeHead(400).end(JSON.stringify({ error: 'texts/text + labels required' }));
        }
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
        res.writeHead(200, { 'Content-Type': 'application/json' })
          .end(JSON.stringify(isBatch ? { batches: mapped, inferenceMs } : { entities: mapped[0], inferenceMs }));
      } catch (err) {
        const detail = err?.stack ?? String(err?.message ?? err);
        console.error(`[bridge] ${isBatch ? 'batch' : 'single'} inference failed:`, detail);
        res.writeHead(500).end(JSON.stringify({ error: String(err?.message ?? err) }));
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
      console.error(`[bridge] listen error:`, err);
      process.exit(1);
    }
  });
  server.listen(p, '127.0.0.1', () => {
    const actual = server.address().port;
    const dir = join(homedir(), '.redactproof');
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'accelerator.json'), JSON.stringify({ port: actual, version: '0.0.1', pid: process.pid }));
    // PID file in install dir so the NSIS uninstaller can kill us cleanly
    // without taskkill'ing every node.exe on the system.
    try { writeFileSync(new URL('./bridge.pid', import.meta.url), String(process.pid)); } catch {}
    console.log(`[bridge] listening on http://127.0.0.1:${actual}`);
    console.log(`[bridge] discovery file: ${join(dir, 'accelerator.json')}`);
  });
}

tryListen(candidates);
