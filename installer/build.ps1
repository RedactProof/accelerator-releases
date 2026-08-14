# Build RedactProof Accelerator installers (x64 + arm64).
#
# Steps per arch:
#   1. Download portable Node.js for the arch into .node-cache\
#   2. Stage payload-<arch>\ with: node.exe, server.mjs, core.bin, package.json
#   3. Run `npm install --omit=dev --cpu=<arch>` inside payload to fetch the
#      correct prebuilt onnxruntime-node native binaries.
#   4. Invoke makensis with /DARCH=<arch> to produce the .exe in dist\.
#
# Outputs land in tools\bridge\dist\.
# Run from anywhere; paths are resolved relative to this script.

$ErrorActionPreference = 'Stop'

$NODE_VERSION = '22.11.0'
$ARCHES = @('x64', 'arm64')

$packageJson = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'package.json') | ConvertFrom-Json
$APP_VERSION = $packageJson.version
Write-Host "Building version $APP_VERSION" -ForegroundColor Cyan

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridgeRoot = Split-Path -Parent $scriptRoot
$distDir    = Join-Path $bridgeRoot 'dist'
$cacheDir   = Join-Path $scriptRoot '.node-cache'

$makensis = @(
    'C:\Program Files (x86)\NSIS\makensis.exe',
    'C:\Program Files\NSIS\makensis.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $makensis) {
    throw 'makensis.exe not found. Install NSIS: winget install NSIS.NSIS'
}

New-Item -ItemType Directory -Force -Path $distDir, $cacheDir | Out-Null

function Download-Node($arch) {
    $zipName = "node-v$NODE_VERSION-win-$arch.zip"
    $zipPath = Join-Path $cacheDir $zipName
    $extractDir = Join-Path $cacheDir "node-v$NODE_VERSION-win-$arch"

    if (-not (Test-Path $extractDir)) {
        if (-not (Test-Path $zipPath)) {
            $url = "https://nodejs.org/dist/v$NODE_VERSION/$zipName"
            Write-Host "[node] downloading $url"
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
        }
        Write-Host "[node] extracting $zipName"
        Expand-Archive -Path $zipPath -DestinationPath $cacheDir -Force
    }
    return Join-Path $extractDir 'node.exe'
}

function Build-Arch($arch) {
    Write-Host "`n=== Building $arch ===" -ForegroundColor Cyan

    $nodeExe = Download-Node $arch
    $payloadDir = Join-Path $distDir "payload-$arch"

    if (Test-Path $payloadDir) { Remove-Item -Recurse -Force $payloadDir }
    New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null

    Copy-Item $nodeExe                              (Join-Path $payloadDir 'node.exe')
    Copy-Item (Join-Path $bridgeRoot 'server.mjs')  $payloadDir
    Copy-Item (Join-Path $bridgeRoot 'core.bin')    $payloadDir
    Copy-Item (Join-Path $bridgeRoot 'package.json') $payloadDir

    # Bundle the tokenizer files so the bridge never hits HuggingFace at
    # runtime. Version-locked to core.bin: any tokenizer drift here will
    # cause /infer 500s on token-id-out-of-bounds.
    $tokenizerSrc = Join-Path $bridgeRoot 'tokenizer'
    if (-not (Test-Path $tokenizerSrc)) {
        throw "Tokenizer files missing at $tokenizerSrc. Run tools\bridge\scripts\download-tokenizer.ps1 first."
    }
    Copy-Item -Recurse $tokenizerSrc (Join-Path $payloadDir 'tokenizer')

    Push-Location $payloadDir
    try {
        Write-Host "[npm] installing prod deps for $arch"
        # IMPORTANT: do NOT use --legacy-peer-deps. It silently downgrades
        # onnxruntime-node to gliner@0.0.19's peer pin (1.19.2) AND introduces
        # a nested @xenova/transformers/node_modules/onnxruntime-node@1.14.0
        # copy. The combo produces a node_modules layout where the .node
        # binding fails to dlopen with BAD_EXE_FORMAT despite being a valid
        # ARM64 binary. Lockfile-based install with --omit=dev gives the same
        # tree shape as a normal local `npm install` and just works.
        #
        # --cpu/--os only used when cross-compiling (host arch != target
        # arch). On host==target, omitting them lets npm pick the right
        # optional deps for the running platform.
        $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        $crossFlags = if ($hostArch -ne $arch) { "--cpu=$arch --os=win32" } else { '' }
        # cmd /c keeps npm's stderr (deprecation warnings) from being parsed
        # as PowerShell errors under $ErrorActionPreference=Stop.
        & cmd /c "npm install --omit=dev $crossFlags --no-audit --no-fund 2>&1" | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "npm install failed for $arch" }
    } finally {
        Pop-Location
    }

    # onnxruntime-node ships native binaries for every platform (linux, darwin,
    # win32-x64, win32-arm64). --cpu/--os don't reach into its postinstall.
    # Strip everything except the platform we're targeting.
    Write-Host "[prune] removing cross-platform onnxruntime binaries"
    $ortDirs = Get-ChildItem -Path $payloadDir -Recurse -Directory -Filter 'onnxruntime-node' -ErrorAction SilentlyContinue
    foreach ($ortDir in $ortDirs) {
        # @xenova/transformers nests an older napi-v3 build; gliner uses napi-v6.
        foreach ($napiVer in @('napi-v3', 'napi-v6')) {
            $napi = Join-Path $ortDir.FullName "bin\$napiVer"
            if (-not (Test-Path $napi)) { continue }
            Get-ChildItem $napi -Directory | ForEach-Object {
                if ($_.Name -ne 'win32') {
                    Remove-Item -Recurse -Force $_.FullName
                } else {
                    Get-ChildItem $_.FullName -Directory | Where-Object { $_.Name -ne $arch } | ForEach-Object {
                        Remove-Item -Recurse -Force $_.FullName
                    }
                }
            }
        }
    }

    # @xenova/transformers/dist ships ONNX Runtime WASM builds for browser use.
    # We use the Node native runtime, never the WASM one. ~36MB.
    Write-Host "[prune] removing transformers WASM bundles + sourcemaps"
    $xenovaDist = Join-Path $payloadDir 'node_modules\@xenova\transformers\dist'
    if (Test-Path $xenovaDist) {
        Get-ChildItem $xenovaDist -File -Filter '*.wasm' | Remove-Item -Force
        Get-ChildItem $xenovaDist -File -Filter '*.map'  | Remove-Item -Force
    }

    # We run inference on Node via onnxruntime-node — never in a browser via
    # onnxruntime-web (WASM). @xenova/transformers statically imports it in
    # backends/onnx.js so we stub instead of delete. ~65MB saved per install.
    Write-Host "[prune] stubbing onnxruntime-web (browser-only WASM build)"
    $ortwDirs = Get-ChildItem -Path $payloadDir -Recurse -Directory -Filter 'onnxruntime-web' -ErrorAction SilentlyContinue
    foreach ($w in $ortwDirs) {
        Remove-Item -Recurse -Force $w.FullName
        New-Item -ItemType Directory -Force -Path $w.FullName | Out-Null
        Set-Content -Path (Join-Path $w.FullName 'package.json') -Value '{"name":"onnxruntime-web","version":"0.0.0-stub","main":"index.js"}' -NoNewline
        Set-Content -Path (Join-Path $w.FullName 'index.js') -Value 'module.exports={InferenceSession:{},Tensor:function(){},env:{wasm:{}}};module.exports.default=module.exports;' -NoNewline
    }

    # sharp is an image-processing native dep used by vision models in
    # @xenova/transformers. We do text-only NER, but transformers statically
    # imports sharp in utils/image.js so we can't just delete it - ESM
    # resolution fails at startup. Replace with a CJS stub. ~47MB saved.
    Write-Host "[prune] stubbing sharp (image processing)"
    $sharpDirs = Get-ChildItem -Path $payloadDir -Recurse -Directory -Filter 'sharp' -ErrorAction SilentlyContinue
    foreach ($s in $sharpDirs) {
        Remove-Item -Recurse -Force $s.FullName
        New-Item -ItemType Directory -Force -Path $s.FullName | Out-Null
        Set-Content -Path (Join-Path $s.FullName 'package.json') -Value '{"name":"sharp","version":"0.0.0-stub","main":"index.js"}' -NoNewline
        Set-Content -Path (Join-Path $s.FullName 'index.js') -Value 'module.exports=function(){throw new Error("sharp stub: vision unsupported in bridge");};module.exports.default=module.exports;' -NoNewline
    }
    Get-ChildItem -Path $payloadDir -Recurse -Directory -Filter '@img' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

    # Branded launcher stub, compiled INTO the payload so it installs
    # alongside start-bridge.vbs. It is the redactproof:// handler target:
    # pointing the scheme straight at schtasks.exe made the browser prompt
    # read "Open Task Scheduler Configuration Tool?", which looks like
    # malware. The stub carries our own FileDescription, so the prompt names
    # RedactProof instead. Architecture-independent (it only shells out), but
    # built per-arch payload for simplicity.
    Write-Host "[nsis] compiling branded launcher stub"
    $launcherNsi = Join-Path $scriptRoot 'launcher.nsi'
    $launcherOut = Join-Path $payloadDir 'LaunchAccelerator.exe'
    & cmd /c "`"$makensis`" /DAPP_VERSION=$APP_VERSION `"/DOUT_FILE=$launcherOut`" `"$launcherNsi`" 2>&1" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "makensis failed for launcher stub" }
    if (-not (Test-Path $launcherOut)) { throw "launcher stub not produced: $launcherOut" }

    Write-Host "[nsis] compiling installer for $arch"
    $nsiPath = Join-Path $scriptRoot 'installer.nsi'
    & cmd /c "`"$makensis`" /DARCH=$arch /DAPP_VERSION=$APP_VERSION `"$nsiPath`" 2>&1" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "makensis failed for $arch" }

    $output = Join-Path $distDir "RedactProof-Accelerator-Setup-$arch-$APP_VERSION.exe"
    if (-not (Test-Path $output)) { throw "Expected output not found: $output" }
    $size = [math]::Round((Get-Item $output).Length / 1MB, 1)
    Write-Host "[ok] $output ($size MB)" -ForegroundColor Green
}

foreach ($arch in $ARCHES) {
    Build-Arch $arch
}

Write-Host "`nDone. Installers in: $distDir" -ForegroundColor Green
Get-ChildItem $distDir -Filter '*.exe' | ForEach-Object {
    $mb = [math]::Round($_.Length / 1MB, 1)
    Write-Host ("  {0}  ({1} MB)" -f $_.Name, $mb)
}
