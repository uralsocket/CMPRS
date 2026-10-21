#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PACKAGE_DIR="$(dirname -- "$SOURCE_DIR")"
APP_PATH="$PACKAGE_DIR/CMPRS Ironclad.app"
SIGNING_IDENTITY="${CMPRS_SIGNING_IDENTITY:-Developer ID Application: Gleb Karavaev (XPPNSDA36S)}"
# Refuse a development/App Store identity before modifying any signature.
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v choice="$SIGNING_IDENTITY" 'index(tolower($0),tolower(choice)) && index($0,"Developer ID Application:") {found=1} END {exit !found}'; then
  printf '%s\n' 'Нужен доступный Developer ID Application с приватным ключом. Задайте CMPRS_SIGNING_IDENTITY, если сертификат называется иначе.'
  exit 1
fi
# Sign nested executable code first, then seal the containing application.
for TOOL_NAME in ffmpeg ffprobe; do
  /usr/bin/codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" --identifier "local.gleb.cmprs-ironclad.$TOOL_NAME" "$APP_PATH/Contents/Resources/bin/$TOOL_NAME"
done
/usr/bin/codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
printf '%s\n' 'Приложение и вложенные инструменты подписаны Developer ID Application. Для новой сборки требуется отдельная нотарификация.'
