#!/bin/bash
# Builds "build/RME Splitter.app". Requires the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/RME Splitter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/RMESplitter" "$APP/Contents/MacOS/RME Splitter"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Templates "$APP/Contents/Resources/Templates"
# Regenerate with: swift Scripts/make-icon.swift icon.png, then sips + iconutil.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
