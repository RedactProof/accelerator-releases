#!/bin/bash
RESOURCES="$(cd "$(dirname "$0")/../Resources" && pwd)"
BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.popsall.redactproof.accelerator.plist"

if [ ! -f "$PLIST" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n  <key>Label</key>\n  <string>com.popsall.redactproof.accelerator</string>\n  <key>ProgramArguments</key>\n  <array>\n    <string>%s/Contents/MacOS/RedactProofAccelerator</string>\n  </array>\n  <key>RunAtLoad</key>\n  <true/>\n  <key>KeepAlive</key>\n  <false/>\n</dict>\n</plist>\n' "$BUNDLE" > "$PLIST"
  launchctl load "$PLIST" 2>/dev/null || true
fi

if pgrep -f "server.mjs" > /dev/null 2>&1; then exit 0; fi
nohup "$RESOURCES/node" "$RESOURCES/server.mjs" > /dev/null 2>&1 &
