#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/dist/FaceUnlock.app"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict --verbose=2 "$APP"
file "$APP/Contents/MacOS/FaceUnlock"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" == true ]]
/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$APP/Contents/Info.plist"
swift build --product ModelCheck --configuration release --arch arm64
BIN_DIR="$(swift build --configuration release --arch arm64 --show-bin-path)"
CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/faceunlock-modelcheck.XXXXXX")"
trap 'rm -rf "$CHECK_ROOT"' EXIT
CHECK_APP="$CHECK_ROOT/ModelCheck.app"
mkdir -p "$CHECK_APP/Contents/MacOS"
cp "$BIN_DIR/ModelCheck" "$CHECK_APP/Contents/MacOS/ModelCheck"
ditto "$APP/Contents/Resources" "$CHECK_APP/Contents/Resources"
cat > "$CHECK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ModelCheck</string>
<key>CFBundleIdentifier</key><string>com.faceunlock.modelcheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
"$CHECK_APP/Contents/MacOS/ModelCheck" --require-app-bundle
# Only disposable copied resources are altered for these negative checks.
mv "$CHECK_APP/Contents/Resources/Models/SFace.mlpackage" "$CHECK_ROOT/SFace.mlpackage"
set +e
"$CHECK_APP/Contents/MacOS/ModelCheck" --require-app-bundle
MISSING_STATUS=$?
set -e
[[ "$MISSING_STATUS" -eq 1 ]] || { echo "Missing model did not fail cleanly" >&2; exit 1; }
echo "PASS: missing packaged model fails closed without a crash or build-directory fallback."
mv "$CHECK_ROOT/SFace.mlpackage" "$CHECK_APP/Contents/Resources/Models/SFace.mlpackage"
printf '%s\n' '{}' > "$CHECK_APP/Contents/Resources/Models/manifest.json"
set +e
"$CHECK_APP/Contents/MacOS/ModelCheck" --require-app-bundle
CORRUPT_STATUS=$?
set -e
[[ "$CORRUPT_STATUS" -eq 1 ]] || { echo "Corrupt model metadata did not fail cleanly" >&2; exit 1; }
echo "PASS: corrupt packaged model metadata fails closed without a crash."
