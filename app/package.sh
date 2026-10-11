#!/bin/bash
# Builds a universal (Apple silicon + Intel) app and wraps it in a disk image
# with an Applications shortcut: build/RME-Splitter-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

SWIFT_FLAGS="--arch arm64 --arch x86_64" ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="build/RME-Splitter-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "build/RME Splitter.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "RME Splitter" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
echo "Built $DMG"
