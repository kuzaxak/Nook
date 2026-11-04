#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Runs scripts/cloudkit/check-production-schema.sh --compare against made-up production exports:
# one lacking fields and a record type schema.ckdb declares fails and names them, one with all
# of them, in a different layout and with extra fields, passes. No token, nothing reaches CloudKit.
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
check=scripts/cloudkit/check-production-schema.sh

grep -v '"device"\|"movedTo"' scripts/cloudkit/schema.ckdb | awk '/RECORD TYPE Item/ { skip = 1 } !skip { print } skip && /\);/ { skip = 0 }' \
  > "$test_dir/behind.ckdb"
status=0
"$check" --compare "$test_dir/behind.ckdb" > "$test_dir/out" 2>&1 || status=$?
[[ "$status" == 1 ]] || { echo "FAIL: a production schema without new fields passed: $(<"$test_dir/out")"; exit 1; }
for missing in Space.device Space.movedTo Item; do
  grep -qx "  $missing" "$test_dir/out" || { echo "FAIL: $missing not named: $(<"$test_dir/out")"; exit 1; }
done
if grep -q "  Space.name" "$test_dir/out"; then echo "FAIL: a field production has was named: $(<"$test_dir/out")"; exit 1; fi

sed -e 's/"\([A-Za-z_]*\)"/\1/' -e 's/^    RECORD TYPE \(.*\) ($/RECORD TYPE \1(/' scripts/cloudkit/schema.ckdb \
  | sed '/"level"/a\
        "extra"         STRING,' > "$test_dir/ahead.ckdb"
"$check" --compare "$test_dir/ahead.ckdb" > "$test_dir/out" 2>&1 || { echo "FAIL: a production schema with every field failed: $(<"$test_dir/out")"; exit 1; }

echo "PASS: production schema check"
