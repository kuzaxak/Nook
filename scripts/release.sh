#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Builds a release of the fork for its own Sparkle feed:
#   scripts/release.sh 1.4.0.1            build, sign, notarize, DMG and appcast in build/release
#   scripts/release.sh 1.4.0.1 --publish  also upload both to a GitHub release on kuzaxak/Nook
#
# The app's feed is https://github.com/kuzaxak/Nook/releases/latest/download/appcast.xml, so the
# newest published release is the update every install sees.
#
# Signing: the "Developer ID Application" identity of team 538SB59LX4 when the login Keychain has
# one (override with SIGN_IDENTITY, or SIGN_IDENTITY=- for ad-hoc); notarization with the
# notarytool profile NOTARY_PROFILE (default nook-notary) when it exists. The DMG is signed for
# Sparkle with the EdDSA key stored in the login Keychain under account ee.qdo.nook (generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
PUBLISH="${2:-}"
TAG="v$VERSION"
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
TEAM=538SB59LX4
ENTITLEMENTS="$PWD/Nook/Nook-CI.entitlements"
SPARKLE_BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
OUT="build/release"
APP="$OUT/Nook.app"

SIGN_IDENTITY="${SIGN_IDENTITY-$(security find-identity -v -p codesigning | grep -o "\"Developer ID Application: [^\"]*($TEAM)\"" | head -1 | tr -d '"')}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE-nook-notary}"
echo "Signing with: $SIGN_IDENTITY"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGNING=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO)
else
  SIGNING=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM" PROVISIONING_PROFILE_SPECIFIER="")
fi

# CI entitlements leave out push and the autofill credential provider, which need a profile.
xcodebuild -scheme Nook -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath build "${SIGNING[@]}" \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  COMPILER_INDEX_STORE_ENABLE=NO

rm -rf "$OUT" && mkdir -p "$OUT"
cp -R build/Build/Products/Release/Nook.app "$APP"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  # Sparkle ships signed by its own team; notarization wants every binary under ours, with a
  # timestamp and the hardened runtime, signed from the inside out.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign() { codesign --force --sign "$SIGN_IDENTITY" --timestamp "$@"; }
  sign --options runtime "$SPARKLE/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  sign --options runtime "$SPARKLE/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  sign --options runtime "$SPARKLE/Updater.app/Contents/MacOS/Updater"
  sign --options runtime "$SPARKLE/Autoupdate"
  sign --options runtime "$SPARKLE/XPCServices/Downloader.xpc"
  sign --options runtime "$SPARKLE/XPCServices/Installer.xpc"
  sign --options runtime "$SPARKLE/Updater.app"
  sign "$SPARKLE/Sparkle"
  sign --options runtime "$SPARKLE"
  sign --options runtime --entitlements "$ENTITLEMENTS" "$APP"
  codesign --verify --deep --strict "$APP"

  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    ditto -c -k --keepParent "$APP" "$OUT/Nook-notarize.zip"
    xcrun notarytool submit "$OUT/Nook-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$OUT/Nook-notarize.zip"
  else
    echo "No notarytool profile \"$NOTARY_PROFILE\"; the release is signed but not notarized."
  fi
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/Nook.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$OUT/feed"
DMG="$OUT/feed/Nook-$VERSION-universal.dmg"
hdiutil create -volname "Nook $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

"$SPARKLE_BIN/generate_appcast" --account ee.qdo.nook \
  --download-url-prefix "https://github.com/kuzaxak/Nook/releases/download/$TAG/" \
  --link "https://github.com/kuzaxak/Nook" "$OUT/feed"

echo "Built $DMG and $OUT/feed/appcast.xml (version $VERSION, build $BUILD_NUMBER)"
if [[ "$PUBLISH" == "--publish" ]]; then
  gh release create "$TAG" "$DMG" "$OUT/feed/appcast.xml" --repo kuzaxak/Nook \
    --title "Nook $VERSION" --notes "Fork build $VERSION (build $BUILD_NUMBER). Universal: Apple silicon and Intel."
else
  echo "Not published. Publish with: scripts/release.sh $VERSION --publish"
fi
