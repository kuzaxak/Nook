#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Stores the secrets .github/workflows/release.yml needs in kuzaxak/Nook:
#   scripts/setup-release-secrets.sh ~/Desktop/devid.p12
#
# Export the identity first: Keychain Access → login → My Certificates → "Developer ID
# Application: …" → File → Export Items… → Personal Information Exchange (.p12), with a password.
# The script asks for that password, the Apple ID and an app-specific password (account.apple.com →
# Sign-In and Security → App-Specific Passwords). The Sparkle key is read from the login Keychain
# (account ee.qdo.nook); macOS asks to allow that once.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=kuzaxak/Nook
TEAM=538SB59LX4
GENERATE_KEYS=build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
P12="${1:?usage: scripts/setup-release-secrets.sh path/to/devid.p12}"

[[ -s "$P12" ]] || { echo "No such file, or it is empty: $P12"; exit 1; }
[[ -x "$GENERATE_KEYS" ]] || { echo "Sparkle's tools are missing: build Nook once so Xcode fetches Sparkle."; exit 1; }

read -rsp "Password of $P12: " P12_PASSWORD; echo
export P12_PASSWORD
# LibreSSL cannot read every .p12 newer Keychain Access writes; then the check is skipped.
if SUBJECT="$(openssl pkcs12 -in "$P12" -nokeys -passin env:P12_PASSWORD 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)"; then
  [[ "$SUBJECT" == *"Developer ID Application"*"$TEAM"* ]] || { echo "Not the Developer ID Application identity of team $TEAM: $SUBJECT"; exit 1; }
else
  echo "Could not read $P12 with openssl; storing it unchecked."
fi

read -rp "Apple ID: " APPLE_ID
read -rsp "App-specific password for $APPLE_ID: " APP_PASSWORD; echo

KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$KEY_DIR"' EXIT
"$GENERATE_KEYS" --account ee.qdo.nook -x "$KEY_DIR/sparkle_key"
[[ -s "$KEY_DIR/sparkle_key" ]] || { echo "No Sparkle key was exported."; exit 1; }

base64 -i "$P12" | gh secret set APPLE_CERTIFICATE_P12_BASE64 -R "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set APPLE_CERTIFICATE_PASSWORD -R "$REPO"
printf '%s' "$APPLE_ID" | gh secret set APPLE_ID -R "$REPO"
printf '%s' "$APP_PASSWORD" | gh secret set APPLE_APP_SPECIFIC_PASSWORD -R "$REPO"
printf '%s' "$TEAM" | gh secret set APPLE_TEAM_ID -R "$REPO"
gh secret set SPARKLE_SIGNING_KEY -R "$REPO" < "$KEY_DIR/sparkle_key"

gh secret list -R "$REPO"
echo "Done. Delete $P12 when you no longer need it."
