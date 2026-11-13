#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p)}"
# Some standalone CLT releases ship Swift Testing outside the compiler's default paths.
FRAMEWORKS="$DEVELOPER_PATH/Library/Developer/Frameworks"
INTEROP="$DEVELOPER_PATH/Library/Developer/usr/lib"
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
    swift test --arch arm64 --disable-xctest \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$INTEROP"
else
    swift test --arch arm64 --disable-xctest
fi
