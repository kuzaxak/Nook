#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Runs scripts/ci-keychain.sh against this Mac's user keychains with a throwaway self-signed
# identity, as the release workflow does on the nook-release runner. The notary step gets fake
# credentials and --no-validate, so notarytool does not contact Apple.
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
security list-keychains -d user > "$test_dir/list-before"
security default-keychain -d user > "$test_dir/default-before"
login_keychain="$HOME/Library/Keychains/login.keychain-db"
notary_account=com.apple.gke.notary.tool.saved-creds.nook-notary
security find-generic-password -a "$notary_account" "$login_keychain" > "$test_dir/login-notary-before" 2>&1 || true

restore_user_keychains() {
  local paths=() line keychain default
  if ! security list-keychains -d user | cmp -s - "$test_dir/list-before"; then
    while IFS= read -r line; do line="${line#*\"}"; paths+=("${line%\"}"); done < "$test_dir/list-before"
    security list-keychains -d user -s "${paths[@]}"
  fi
  if ! security default-keychain -d user | cmp -s - "$test_dir/default-before"; then
    default="$(<"$test_dir/default-before")"; default="${default#*\"}"
    security default-keychain -d user -s "${default%\"}"
  fi
  for keychain in "$test_dir"/*/*.keychain-db; do
    if [[ -e "$keychain" ]]; then security delete-keychain "$keychain"; fi
  done
  rm -rf "$test_dir"
}
trap restore_user_keychains EXIT

fail() { echo "FAIL: $*"; exit 1; }

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$test_dir/key.pem" -out "$test_dir/cert.pem" \
  -subj "/CN=Developer ID Application: Nook Keychain Check (TESTTEAM00)/OU=TESTTEAM00" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$test_dir/key.pem" -in "$test_dir/cert.pem" -out "$test_dir/identity.p12" -passout pass:check
APPLE_CERTIFICATE_P12_BASE64="$(base64 -i "$test_dir/identity.p12")"
APPLE_CERTIFICATE_PASSWORD=check
export APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD

run() {
  local dir="$test_dir/$1"
  shift
  mkdir -p "$dir" && touch "$dir/env"
  RUNNER_TEMP="$dir" GITHUB_ENV="$dir/env" scripts/ci-keychain.sh "$@"
}

exported() { sed -n "s/^$2=//p" "$test_dir/$1/env" | tail -1; }

assert_user_keychains_restored() {
  security list-keychains -d user > "$test_dir/list-after"
  security default-keychain -d user > "$test_dir/default-after"
  cmp -s "$test_dir/list-before" "$test_dir/list-after" || fail "$1: search list changed: $(tr -s ' \n' ' ' < "$test_dir/list-after")"
  cmp -s "$test_dir/default-before" "$test_dir/default-after" || fail "$1: default keychain changed"
}

assert_cleaned() {
  [[ ! -e "$test_dir/$1/nook-release.keychain-db" ]] || fail "$1: temporary keychain left behind"
  [[ -z "$(find "$test_dir/$1" -name '*.p12')" ]] || fail "$1: certificate file left behind"
}

run signed setup
identity="$(exported signed SIGN_IDENTITY)"
keychain="$(exported signed SIGN_KEYCHAIN)"
[[ "$identity" =~ ^[0-9A-F]{40}$ ]] || fail "SIGN_IDENTITY is not a SHA-1: '$identity'"
[[ -e "$keychain" ]] || fail "SIGN_KEYCHAIN does not exist: '$keychain'"
cp /usr/bin/true "$test_dir/signed/tool"
codesign --force --sign "$identity" --keychain "$keychain" "$test_dir/signed/tool"
signature="$(codesign -dvv "$test_dir/signed/tool" 2>&1)"
grep -qx "Authority=Developer ID Application: Nook Keychain Check (TESTTEAM00)" <<< "$signature" \
  || fail "the test binary is not signed with the throwaway identity: $signature"
APPLE_ID=check@example.com APPLE_TEAM_ID=TESTTEAM00 APPLE_APP_SPECIFIC_PASSWORD=not-a-password \
  run signed notary --no-validate
[[ "$(exported signed NOTARY_KEYCHAIN)" == "$keychain" ]] || fail "NOTARY_KEYCHAIN is not the temporary keychain"
security find-generic-password -a "$notary_account" "$keychain" > /dev/null || fail "nook-notary is not in the temporary keychain"
security find-generic-password -a "$notary_account" "$login_keychain" > "$test_dir/login-notary-after" 2>&1 || true
cmp -s "$test_dir/login-notary-before" "$test_dir/login-notary-after" || fail "the login keychain's nook-notary item changed"
run signed cleanup
assert_user_keychains_restored "signed run"
assert_cleaned signed

run killed setup
run killed setup
run killed cleanup
assert_user_keychains_restored "killed run, same RUNNER_TEMP"
assert_cleaned killed

run emptied setup
rm -rf "$test_dir/emptied"
run next setup
run next cleanup
assert_user_keychains_restored "killed run whose RUNNER_TEMP the runner emptied"
assert_cleaned next

run abandoned setup
rm -rf "$test_dir/abandoned"
run failed-early cleanup
assert_user_keychains_restored "cleanup without setup after a killed run"

run edited setup
mkdir -p "$test_dir/user"
security create-keychain -p check "$test_dir/user/added.keychain-db"
paths=()
while IFS= read -r line; do line="${line#*\"}"; paths+=("${line%\"}"); done < <(security list-keychains -d user)
security list-keychains -d user -s "${paths[@]}" "$test_dir/user/added.keychain-db"
run edited cleanup
security list-keychains -d user | grep -q '/user/added.keychain-db"$' || fail "cleanup dropped a keychain the user added during the job"
security delete-keychain "$test_dir/user/added.keychain-db"
assert_user_keychains_restored "keychain added during the job"
assert_cleaned edited

mkdir -p "$test_dir/fake-bin"
cat > "$test_dir/fake-bin/security" <<'FAKE'
#!/bin/bash
case "$*" in
  "list-keychains -d user") echo '    "/runner/_temp/nook-release.keychain-db"' ;;
  "list-keychains -d user -s"*) echo "$*" >> "$(dirname "$0")/calls" ;;
esac
FAKE
chmod +x "$test_dir/fake-bin/security"
status=0
PATH="$test_dir/fake-bin:$PATH" run lone cleanup || status=$?
[[ ! -e "$test_dir/fake-bin/calls" ]] || fail "cleanup set the search list to: $(<"$test_dir/fake-bin/calls")"
[[ "$status" != 0 ]] || fail "cleanup reported success with nothing left on the search list"

echo "ci-keychain check passed"
