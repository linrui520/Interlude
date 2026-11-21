#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
DESTINATION="${1:-$SOURCE_DIR/Build}"
APP="$DESTINATION/间奏.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DESTINATION/ModuleCache"
xcrun swiftc \
    -O -whole-module-optimization \
    -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$DESTINATION/ModuleCache" \
    -Xfrontend -disable-sandbox \
    "$SOURCE_DIR"/Sources/*.swift \
    -o "$APP/Contents/MacOS/Interlude"
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
ditto "$SOURCE_DIR/Resources" "$APP/Contents/Resources"
cp "$SOURCE_DIR/LICENSE.txt" "$APP/Contents/Resources/LICENSE.txt"
codesign --force --sign - "$APP"
echo "已生成 $APP"
