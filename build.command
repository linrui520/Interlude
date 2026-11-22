#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
DESTINATION="${1:-$SOURCE_DIR/Build}"
mkdir -p "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"
# Xcode also extracts the App Intents metadata used by macOS Shortcuts.
xcodebuild -quiet -project "$SOURCE_DIR/Interlude.xcodeproj" -scheme Interlude \
    -configuration Release -derivedDataPath "$DESTINATION/DerivedData" \
    -destination 'generic/platform=macOS' ARCHS="$(uname -m)" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
APP="$DESTINATION/间奏.app"
ditto "$DESTINATION/DerivedData/Build/Products/Release/间奏.app" "$APP"
codesign --verify --strict "$APP"
test -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
echo "已生成 Interlude Pre-2: $APP"
