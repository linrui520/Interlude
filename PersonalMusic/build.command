#!/bin/bash
set -euo pipefail
PLAYER_SOURCE="$(cd "$(dirname "$0")" && pwd)"
DESTINATION="${1:-$PLAYER_SOURCE/Build}"
APP="$DESTINATION/间奏个人音乐.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DESTINATION/ModuleCache"
xcrun swiftc -O -whole-module-optimization \
    -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$DESTINATION/ModuleCache" -Xfrontend -disable-sandbox \
    "$PLAYER_SOURCE/PersonalMusic.swift" "$PLAYER_SOURCE/../Sources/Music.swift" "$PLAYER_SOURCE/../Sources/AppSettings.swift" "$PLAYER_SOURCE/../Sources/MotionDesign.swift" \
    -o "$APP/Contents/MacOS/InterludePersonalMusic"
cp "$PLAYER_SOURCE/Info.plist" "$APP/Contents/Info.plist"
cp "$PLAYER_SOURCE/../Resources/Interlude.icns" "$APP/Contents/Resources/"
cp "$PLAYER_SOURCE/../LICENSE.txt" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "已生成 $APP"
