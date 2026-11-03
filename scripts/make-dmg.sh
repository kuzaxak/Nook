#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Builds the universal (arm64 + x86_64) Release app, ad-hoc signed, and packs it into
# build/Nook-universal.dmg with an /Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -scheme Nook -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="$PWD/Nook/Nook-CI.entitlements"

APP="build/Build/Products/Release/Nook.app"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/Nook.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname Nook -srcfolder "$STAGING" -ov -format UDZO build/Nook-universal.dmg
echo "build/Nook-universal.dmg"
