#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Signing and notarization credentials for .github/workflows/release.yml, which runs on the
# self-hosted nook-release runner as the Mac user's own account:
#   scripts/ci-keychain.sh setup    temporary keychain in RUNNER_TEMP with the Developer ID identity
#   scripts/ci-keychain.sh notary   notarytool profile nook-notary in that keychain; further
#                                   arguments go to notarytool store-credentials
#   scripts/ci-keychain.sh cleanup  takes the temporary keychains off the user's keychain search
#                                   list and deletes this run's
#
# setup reads APPLE_CERTIFICATE_P12_BASE64 and APPLE_CERTIFICATE_PASSWORD and exports SIGN_KEYCHAIN
# and SIGN_IDENTITY (the identity's SHA-1); notary reads APPLE_ID, APPLE_TEAM_ID and
# APPLE_APP_SPECIFIC_PASSWORD and exports NOTARY_KEYCHAIN. Exports are appended to GITHUB_ENV when
# it is set. The default keychain is never changed.
set -euo pipefail

: "${RUNNER_TEMP:?}"
KEYCHAIN_NAME=nook-release.keychain-db
KEYCHAIN="$RUNNER_TEMP/$KEYCHAIN_NAME"
P12="$RUNNER_TEMP/nook-release.p12"

# A run killed before cleanup leaves its keychain on the list, at a RUNNER_TEMP the runner may
# since have emptied.
read_search_list_without_temp() {
  local line path
  LIST=()
  while IFS= read -r line; do
    path="${line#*\"}"; path="${path%\"}"
    [[ "${path##*/}" == "$KEYCHAIN_NAME" ]] || LIST+=("$path")
  done < <(security list-keychains -d user)
}

export_env() {
  echo "$1=$2"
  if [[ -n "${GITHUB_ENV:-}" ]]; then echo "$1=$2" >> "$GITHUB_ENV"; fi
}

case "${1:-}" in
  setup)
    : "${APPLE_CERTIFICATE_P12_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}"
    if [[ -e "$KEYCHAIN" ]]; then security delete-keychain "$KEYCHAIN"; fi
    PASSWORD="$(uuidgen)"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
    (umask 077; printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$P12")
    security import "$P12" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
    rm "$P12"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" > /dev/null
    read_search_list_without_temp
    security list-keychains -d user -s "$KEYCHAIN" ${LIST[@]+"${LIST[@]}"}
    IDENTITIES="$(security find-identity -p codesigning "$KEYCHAIN")"
    echo "$IDENTITIES"
    IDENTITY="$(awk '/"Developer ID Application: / { print $2; exit }' <<< "$IDENTITIES")"
    [[ -n "$IDENTITY" ]] || { echo "The certificate holds no Developer ID Application identity."; exit 1; }
    export_env SIGN_KEYCHAIN "$KEYCHAIN"
    export_env SIGN_IDENTITY "$IDENTITY"
    ;;
  notary)
    : "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_SPECIFIC_PASSWORD:?}"
    shift
    xcrun notarytool store-credentials nook-notary --keychain "$KEYCHAIN" \
      --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" "$@"
    export_env NOTARY_KEYCHAIN "$KEYCHAIN"
    ;;
  cleanup)
    read_search_list_without_temp
    if [[ -e "$KEYCHAIN" ]]; then security delete-keychain "$KEYCHAIN"; fi
    rm -f "$P12"
    [[ ${#LIST[@]} -gt 0 ]] || { echo "Only temporary keychains are on the search list; it is left as it is."; exit 1; }
    security list-keychains -d user -s "${LIST[@]}"
    ;;
  *)
    echo "usage: scripts/ci-keychain.sh setup|notary|cleanup"
    exit 1
    ;;
esac
