# Pull the tokenizer files for the bridge from R2 via the production worker.
#
# These are the *same* tokenizer files the web bundle loads at runtime, so
# they are guaranteed to pair with the model the rest of the platform is
# already using. The previous bridge implementation hit HuggingFace live on
# every start, which (a) leaked the model identity in network traffic,
# (b) broke the bridge whenever HF nudged the tokenizer config out of sync
# with the shipped core.bin, and (c) made the bridge unusable offline.
#
# Run once after cloning, or whenever core.bin is re-uploaded to R2. The
# downloaded files get committed to the repo and the installer copies them
# into payload-<arch>\tokenizer\ at build time.
#
# Override the source via -ApiBase if you want to pull from staging:
#   .\download-tokenizer.ps1 -ApiBase https://staging-api.redactproof.com

param(
    [string]$ApiBase = 'https://api.redactproof.com'
)

$ErrorActionPreference = 'Stop'

$FILES = @(
    'tokenizer.json',
    'tokenizer_config.json'
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridgeRoot = Split-Path -Parent $scriptRoot
$destDir = Join-Path $bridgeRoot 'tokenizer'

New-Item -ItemType Directory -Force -Path $destDir | Out-Null

Write-Host "Downloading tokenizer from $ApiBase" -ForegroundColor Cyan

foreach ($f in $FILES) {
    $url = "$ApiBase/model/pii/resolve/main/$f"
    $out = Join-Path $destDir $f
    Write-Host "  $f"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
}

# Stamp the source so a future maintainer can tell which environment these
# files came from without grovelling through git history.
$stamp = "source: $ApiBase`ndownloaded: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
Set-Content -Path (Join-Path $destDir 'SOURCE.txt') -Value $stamp -NoNewline

Write-Host "`nDone. Files in: $destDir" -ForegroundColor Green
Get-ChildItem $destDir | ForEach-Object {
    $kb = [math]::Round($_.Length / 1KB, 1)
    Write-Host ("  {0}  ({1} KB)" -f $_.Name, $kb)
}
