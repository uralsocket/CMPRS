#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 Source/BuildInstaller.py
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path build/swift-cache Source/Installer.swift -framework AppKit -o 'Installer-build/CMPRS Installer.app/Contents/MacOS/CMPRSInstaller'
if [[ -n "${CMPRS_SIGNING_IDENTITY:-}" ]]; then
 codesign --force --options runtime --timestamp --sign "$CMPRS_SIGNING_IDENTITY" 'Installer-build/CMPRS Installer.app'
else
 codesign --force --sign - 'Installer-build/CMPRS Installer.app'
fi
codesign --verify --deep --strict 'Installer-build/CMPRS Installer.app'
