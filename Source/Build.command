#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ ! -x build/prefix/bin/ffmpeg || ! -x build/prefix/bin/ffprobe ]]; then bash Source/BuildEngines.sh; fi
python3 Source/Assemble.py
mkdir -p build/swift-cache
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path build/swift-cache Source/CMPRS.swift -framework AppKit -o 'CMPRS Ironclad.app/Contents/MacOS/CMPRS'
if [[ -n "${CMPRS_SIGNING_IDENTITY:-}" ]]; then
  bash Source/Sign.command
else
  for name in ffmpeg ffprobe; do codesign --force --sign - "CMPRS Ironclad.app/Contents/Resources/bin/$name"; done
  codesign --force --sign - 'CMPRS Ironclad.app'
fi
printf '%s\n' 'Built CMPRS. Public distribution requires Developer ID signing and Apple notarization.'
