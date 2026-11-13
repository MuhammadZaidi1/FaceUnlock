#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "Usage: bash scripts/package-app.sh [debug|release]" >&2; exit 2 ;;
esac

for RESOURCE in SFace.mlpackage manifest.json SFace-LICENSE.txt SFace-NOTICE.txt; do
    [[ -e "$ROOT/Sources/FaceModel/Models/$RESOURCE" ]] || { echo "Missing model resource: $RESOURCE" >&2; exit 1; }
done
swift build --product FaceUnlock --configuration "$CONFIGURATION" --arch arm64
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --arch arm64 --show-bin-path)"
APP="$ROOT/dist/FaceUnlock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Include the real model, provenance manifest, and model-specific license.
# Remove only this generated resource directory so no stale conversion files survive.
rm -rf "$APP/Contents/Resources/Models"
ditto "$ROOT/Sources/FaceModel/Models" "$APP/Contents/Resources/Models"
cp "$BIN_DIR/FaceUnlock" "$APP/Contents/MacOS/FaceUnlock"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/FaceUnlock"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Packaged: $APP"
