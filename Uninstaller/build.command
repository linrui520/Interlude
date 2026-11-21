#!/bin/bash
set -euo pipefail
UNINSTALL_SOURCE="$(cd "$(dirname "$0")" && pwd)"
DESTINATION="${1:-$UNINSTALL_SOURCE/Build}"
APP="$DESTINATION/卸载间奏.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DESTINATION/ModuleCache"
xcrun swiftc -O -whole-module-optimization \
    -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$DESTINATION/ModuleCache" -Xfrontend -disable-sandbox \
    "$UNINSTALL_SOURCE"/*.swift -o "$APP/Contents/MacOS/InterludeUninstaller"
cp "$UNINSTALL_SOURCE/Info.plist" "$APP/Contents/Info.plist"
cp "$UNINSTALL_SOURCE/../Resources/Interlude.icns" "$APP/Contents/Resources/"
for lang in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "$UNINSTALL_SOURCE/$lang.lproj/InfoPlist.strings" "$APP/Contents/Resources/$lang.lproj/"
done
cp "$UNINSTALL_SOURCE/../LICENSE.txt" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "已生成 $APP"
