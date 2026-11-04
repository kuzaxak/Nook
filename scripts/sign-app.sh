#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Signs a built Nook.app for release:
#   scripts/sign-app.sh build/release/Nook.app
#
# Embeds the Developer ID provisioning profile as Contents/embedded.provisionprofile, signs
# Sparkle's helpers and then the app from the inside out with Nook/Nook-Release.entitlements and
# the hardened runtime, and checks that the signed app holds the iCloud and push entitlements
# and that the profile grants every entitlement it governs. scripts/release.sh runs it.
#
# The profile comes from NOOK_PROVISIONING_PROFILE (the file in base64, as the release
# workflow's secret holds it) or from the file at NOOK_PROVISIONING_PROFILE_PATH; with neither
# it stops. SIGN_IDENTITY names the identity, and SIGN_KEYCHAIN the keychain it is in. An ad hoc
# identity (-) signs without a timestamp: such an app does not launch with these entitlements,
# but its entitlements and embedded profile can be checked.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: scripts/sign-app.sh path/to/Nook.app}"
: "${SIGN_IDENTITY:?SIGN_IDENTITY names the signing identity}"
TEAM=538SB59LX4
APP_ID="$TEAM.ee.qdo.nook"
ENTITLEMENTS="$PWD/Nook/Nook-Release.entitlements"
REQUIRED=(
  com.apple.application-identifier
  com.apple.developer.team-identifier
  com.apple.developer.icloud-container-identifiers
  com.apple.developer.icloud-services
  com.apple.developer.icloud-container-environment
  com.apple.developer.aps-environment
)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -d "$APP/Contents/MacOS" ]] || { echo "Not an app bundle: $APP"; exit 1; }
if [[ -n "${NOOK_PROVISIONING_PROFILE:-}" ]]; then
  PROFILE="$WORK/Nook.provisionprofile"
  printf '%s' "$NOOK_PROVISIONING_PROFILE" | base64 --decode > "$PROFILE"
elif [[ -n "${NOOK_PROVISIONING_PROFILE_PATH:-}" ]]; then
  PROFILE="$NOOK_PROVISIONING_PROFILE_PATH"
else
  echo "No provisioning profile. Set NOOK_PROVISIONING_PROFILE to the Developer ID profile in base64, or"
  echo "NOOK_PROVISIONING_PROFILE_PATH to its file; release builds embed it so spaces can sync through iCloud."
  exit 1
fi
[[ -s "$PROFILE" ]] || { echo "The provisioning profile is missing or empty: $PROFILE"; exit 1; }

security cms -D -i "$PROFILE" -o "$WORK/profile.plist" 2>/dev/null || { echo "Not a provisioning profile: $PROFILE"; exit 1; }
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORK/profile.plist" > "$WORK/granted.plist"

# The values of KEY in PLIST, one per line: a string or each item of an array.
values() {
  local out
  out="$(/usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null)" || return 1
  if [[ "$out" == "Array {"* ]]; then
    sed -e '1d' -e '$d' -e 's/^ *//' <<< "$out"
  else
    printf '%s\n' "$out"
  fi
}

# Whether the profile grants VALUE for KEY: the same value, or a pattern such as * or TEAM.*.
granted() {
  local pattern
  while IFS= read -r pattern; do
    # shellcheck disable=SC2053
    [[ "$1" == $pattern ]] && return 0
  done < <(values "$WORK/granted.plist" "$2")
  return 1
}

# Fails when PLIST lacks a required entitlement, or holds one the profile governs and does not grant.
check() {
  local key value failed=0
  for key in "${REQUIRED[@]}"; do
    values "$1" "$key" > /dev/null || { echo "$2 has no $key."; failed=1; }
  done
  while IFS= read -r key; do
    [[ "$key" == com.apple.developer.* || "$key" == com.apple.application-identifier || "$key" == keychain-access-groups ]] || continue
    while IFS= read -r value; do
      granted "$value" "$key" || { echo "The provisioning profile does not grant $key = $value in $2."; failed=1; }
    done < <(values "$1" "$key")
  done < <(/usr/libexec/PlistBuddy -c Print "$1" | sed -n 's/^    \([^ ]*\) = .*/\1/p')
  return "$failed"
}

[[ "$(values "$WORK/profile.plist" TeamIdentifier)" == "$TEAM" ]] || { echo "The provisioning profile is not team $TEAM's."; exit 1; }
[[ "$(values "$WORK/granted.plist" com.apple.application-identifier)" == "$APP_ID" ]] || { echo "The provisioning profile is not for $APP_ID."; exit 1; }
EXPIRES="$(plutil -extract ExpirationDate raw -o - "$WORK/profile.plist")"
[[ "$EXPIRES" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || { echo "The provisioning profile expired at $EXPIRES."; exit 1; }
check "$ENTITLEMENTS" "Nook/Nook-Release.entitlements" || exit 1

cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

TIMESTAMP=--timestamp
[[ "$SIGN_IDENTITY" != "-" ]] || TIMESTAMP=--timestamp=none
sign() { codesign --force --sign "$SIGN_IDENTITY" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$TIMESTAMP" "$@"; }
# Sparkle ships signed by its own team; notarization wants every binary under ours, with a
# timestamp and the hardened runtime, signed from the inside out.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
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

codesign -d --entitlements :- "$APP" > "$WORK/signed.plist" 2>/dev/null
check "$WORK/signed.plist" "$APP" || exit 1
cmp -s "$PROFILE" "$APP/Contents/embedded.provisionprofile" || { echo "$APP does not embed the provisioning profile."; exit 1; }
echo "Signed $APP with the embedded profile; its entitlements match the profile:"
for key in "${REQUIRED[@]}"; do
  echo "  $key = $(values "$WORK/signed.plist" "$key" | paste -sd, -)"
done
