#!/bin/bash
# Builds "build/RME Splitter.app". Requires the Xcode command line tools.
# Set SWIFT_FLAGS to pass extra build flags, e.g. "--arch arm64 --arch x86_64".
set -euo pipefail
cd "$(dirname "$0")"

FLAGS=(-c release ${SWIFT_FLAGS:-})
swift build "${FLAGS[@]}"
APP="build/RME Splitter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build "${FLAGS[@]}" --show-bin-path)/RMESplitter" "$APP/Contents/MacOS/RME Splitter"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Templates "$APP/Contents/Resources/Templates"
# Regenerate with: swift Scripts/make-icon.swift icon.png, then sips + iconutil.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
