#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "Usage: bash scripts/package-app.sh [debug|release]" >&2; exit 2 ;;
esac

swift build --configuration "$CONFIGURATION" --arch arm64
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --arch arm64 --show-bin-path)"
APP="$ROOT/dist/FaceUnlock.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/FaceUnlock" "$APP/Contents/MacOS/FaceUnlock"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/FaceUnlock"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Packaged: $APP"
