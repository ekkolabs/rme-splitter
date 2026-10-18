#!/bin/bash
# Builds a universal (Apple silicon + Intel) app and wraps it in an installer
# package that puts it in /Applications: build/RME-Splitter-<version>.pkg
set -euo pipefail
cd "$(dirname "$0")"

SWIFT_FLAGS="--arch arm64 --arch x86_64" ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
PKG="build/RME-Splitter-$VERSION.pkg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

mkdir "$STAGING/root"
cp -R "build/RME Splitter.app" "$STAGING/root/"

# Always install to /Applications, rather than "upgrading" some other copy of
# the app the installer finds on disk (such as this build folder).
pkgbuild --analyze --root "$STAGING/root" "$STAGING/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$STAGING/components.plist"

pkgbuild --quiet --root "$STAGING/root" --component-plist "$STAGING/components.plist" \
    --install-location /Applications --identifier "$BUNDLE_ID" --version "$VERSION" \
    "$STAGING/component.pkg"
rm -f "$PKG"
productbuild --quiet --package "$STAGING/component.pkg" "$PKG"
echo "Built $PKG"
