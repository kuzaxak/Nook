#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Builds a release of the fork for its own Sparkle feed:
#   scripts/release.sh 1.4.0.1             build, sign, notarize, DMG and appcast in build/release
#   scripts/release.sh 1.4.0.1 --publish   also upload both to a GitHub release on kuzaxak/Nook
#   scripts/release.sh 1.4.0.1 --app-only  only build/release/Nook.app, signed and not notarized
#
# The app's feed is https://github.com/kuzaxak/Nook/releases/latest/download/appcast.xml, so the
# newest published release is the update every install sees.
#
# Signing: the "Developer ID Application" identity of team 538SB59LX4 when the login Keychain has
# one (override with SIGN_IDENTITY, or SIGN_IDENTITY=- for ad-hoc). A Developer ID build embeds
# the Developer ID provisioning profile, from NOOK_PROVISIONING_PROFILE (base64) or the file at
# NOOK_PROVISIONING_PROFILE_PATH, and is signed with Nook/Nook-Release.entitlements by
# scripts/sign-app.sh, so spaces sync through iCloud; without a profile the script stops. An
# ad-hoc build keeps Nook/Nook-CI.entitlements and does not sync. A Developer ID build is
# notarized with the notarytool profile NOTARY_PROFILE (default nook-notary) and the script stops
# if that fails; NOTARY_PROFILE= skips notarization. SIGN_KEYCHAIN and NOTARY_KEYCHAIN name the
# keychain the identity and the profile are read from instead of the search list. The DMG is signed
# for Sparkle with the EdDSA key stored in the login Keychain under account ee.qdo.nook
# (generate_keys), or with the key in SPARKLE_KEY (CI), which reaches generate_appcast on stdin.
# Both login Keychain items may ask for access the first time: run it at the Mac and choose Always
# Allow.
# .github/workflows/release.yml runs this script for version tags on the self-hosted nook-release
# runner, with a temporary keychain from scripts/ci-keychain.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish | --app-only]}"
PUBLISH="${2:-}"
[[ -z "$PUBLISH" || "$PUBLISH" == "--publish" || "$PUBLISH" == "--app-only" ]] || { echo "Unknown option: $PUBLISH"; exit 1; }
TAG="v$VERSION"
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
TEAM=538SB59LX4
BUILD_ENTITLEMENTS="$PWD/Nook/Nook-CI.entitlements"
SPARKLE_BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
OUT="build/release"
APP="$OUT/Nook.app"
export -n SPARKLE_KEY

# A tag that already names another commit would get this build's binaries; stop before building.
if [[ "$PUBLISH" == "--publish" ]]; then
  REMOTE="https://github.com/kuzaxak/Nook.git"
  TAG_COMMIT="$(git ls-remote "$REMOTE" "refs/tags/$TAG^{}" | cut -f1)"
  [[ -n "$TAG_COMMIT" ]] || TAG_COMMIT="$(git ls-remote "$REMOTE" "refs/tags/$TAG" | cut -f1)"
  if [[ -n "$TAG_COMMIT" && "$TAG_COMMIT" != "$(git rev-parse HEAD)" ]]; then
    echo "$TAG already points at $TAG_COMMIT, not at $(git rev-parse HEAD)."
    exit 1
  fi
fi

SIGN_IDENTITY="${SIGN_IDENTITY-$(security find-identity -v -p codesigning | grep -o "\"Developer ID Application: [^\"]*($TEAM)\"" | head -1 | tr -d '"')}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE-nook-notary}"
echo "Signing with: $SIGN_IDENTITY"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Ad-hoc build: Nook/Nook-CI.entitlements and no provisioning profile, so spaces do not sync."
  SIGNING=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO)
else
  if [[ -z "${NOOK_PROVISIONING_PROFILE:-}" && -z "${NOOK_PROVISIONING_PROFILE_PATH:-}" ]]; then
    echo "No provisioning profile. Set NOOK_PROVISIONING_PROFILE to the Developer ID profile in base64, or"
    echo "NOOK_PROVISIONING_PROFILE_PATH to its file; release builds embed it so spaces can sync through iCloud."
    exit 1
  fi
  SIGNING=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM" PROVISIONING_PROFILE_SPECIFIER="")
  [[ -z "${SIGN_KEYCHAIN:-}" ]] || SIGNING+=(OTHER_CODE_SIGN_FLAGS="--keychain \"$SIGN_KEYCHAIN\"")
fi

# xcodebuild wants an installed profile for entitlements that need one, so it signs with the CI
# entitlements; scripts/sign-app.sh signs the app again with the release ones and the profile.
xcodebuild -scheme Nook -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath build "${SIGNING[@]}" \
  CODE_SIGN_ENTITLEMENTS="$BUILD_ENTITLEMENTS" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  COMPILER_INDEX_STORE_ENABLE=NO

rm -rf "$OUT" && mkdir -p "$OUT"
cp -R build/Build/Products/Release/Nook.app "$APP"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  sign() { codesign --force --sign "$SIGN_IDENTITY" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} --timestamp "$@"; }
  SIGN_IDENTITY="$SIGN_IDENTITY" SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}" scripts/sign-app.sh "$APP"
  if [[ "$PUBLISH" == "--app-only" ]]; then
    echo "Built $APP (version $VERSION, build $BUILD_NUMBER): signed, not notarized."
    exit 0
  fi

  if [[ -n "$NOTARY_PROFILE" ]]; then
    ditto -c -k --keepParent "$APP" "$OUT/Nook-notarize.zip"
    xcrun notarytool submit "$OUT/Nook-notarize.zip" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait | tee "$OUT/notarize.log"
    grep -q "status: Accepted" "$OUT/notarize.log" || { echo "Notarization was not accepted; see $OUT/notarize.log"; exit 1; }
    xcrun stapler staple "$APP"
    rm "$OUT/Nook-notarize.zip"
  else
    echo "NOTARY_PROFILE is empty; the release is signed but not notarized."
  fi
fi

if [[ "$PUBLISH" == "--app-only" ]]; then
  echo "Built $APP (version $VERSION, build $BUILD_NUMBER): ad-hoc signed."
  exit 0
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/Nook.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$OUT/feed"
DMG="$OUT/feed/Nook-$VERSION-universal.dmg"
hdiutil create -volname "Nook $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  sign "$DMG"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait | tee "$OUT/notarize-dmg.log"
    grep -q "status: Accepted" "$OUT/notarize-dmg.log" || { echo "DMG notarization was not accepted; see $OUT/notarize-dmg.log"; exit 1; }
    xcrun stapler staple "$DMG"
  fi
fi

# The version's CHANGELOG.md section is the release's notes, on GitHub and in Sparkle's update
# window, which embeds an .html file named like the DMG.
NOTES="$OUT/notes.md"
awk -v v="$VERSION" '/^## / { on = ($2 == v); next } on' CHANGELOG.md > "$NOTES"
[[ -s "$NOTES" ]] || echo "Fork build $VERSION. Universal: Apple silicon and Intel." > "$NOTES"
awk '
  { gsub(/&/, "\\&amp;"); gsub(/</, "\\&lt;"); gsub(/>/, "\\&gt;") }
  /^### / { if (list) { print "</ul>"; list = 0 } sub(/^### /, ""); print "<h3>" $0 "</h3>"; next }
  /^- / { if (!list) { print "<ul>"; list = 1 } sub(/^- /, ""); print "<li>" $0 "</li>"; next }
  /^[[:space:]]*$/ { next }
  { if (list) { print "</ul>"; list = 0 } print "<p>" $0 "</p>" }
  END { if (list) print "</ul>" }
' "$NOTES" > "${DMG%.dmg}.html"

if [[ -n "${SPARKLE_KEY:-}" ]]; then
  SPARKLE_KEY_SOURCE=(--ed-key-file -)
else
  SPARKLE_KEY_SOURCE=(--account ee.qdo.nook)
fi
printf '%s' "${SPARKLE_KEY:-}" | "$SPARKLE_BIN/generate_appcast" "${SPARKLE_KEY_SOURCE[@]}" \
  --download-url-prefix "https://github.com/kuzaxak/Nook/releases/download/$TAG/" \
  --link "https://github.com/kuzaxak/Nook" "$OUT/feed"
# generate_appcast exits 0 and leaves the entry unsigned when the key doesn't match the app's.
grep -q 'sparkle:edSignature=' "$OUT/feed/appcast.xml" || { echo "appcast.xml is unsigned; check the Sparkle key"; exit 1; }

echo "Built $DMG and $OUT/feed/appcast.xml (version $VERSION, build $BUILD_NUMBER)"
if [[ "$PUBLISH" == "--publish" ]]; then
  # A rerun after a failed upload replaces the files on the release it already made.
  if gh release view "$TAG" --repo kuzaxak/Nook >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$OUT/feed/appcast.xml" --repo kuzaxak/Nook --clobber
  else
    gh release create "$TAG" "$DMG" "$OUT/feed/appcast.xml" --repo kuzaxak/Nook --target "$(git rev-parse HEAD)" \
      --title "Nook $VERSION" --notes-file "$NOTES"
  fi
else
  echo "Not published. Publish with: scripts/release.sh $VERSION --publish"
fi
