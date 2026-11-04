#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Checks that the production environment of the iCloud.ee.qdo.nook container has every record
# type and field scripts/cloudkit/schema.ckdb declares. CloudKit refuses a save that carries a
# field production lacks, so run this before every release:
#   scripts/cloudkit/check-production-schema.sh path/to/management-token
# It exits 1 and lists what production lacks; import the schema with import-schema.sh and deploy
# it to production in CloudKit Console, then check again. The token file reaches cktool in
# CLOUDKIT_MANAGEMENT_TOKEN only, as in import-schema.sh.
#   scripts/cloudkit/check-production-schema.sh --compare exported.ckdb
# compares against a schema exported earlier instead, without a token.
set -euo pipefail

usage="usage: scripts/cloudkit/check-production-schema.sh path/to/management-token | --compare exported.ckdb"
[[ $# -ge 1 ]] || { echo "$usage"; exit 2; }
schema="$(cd "$(dirname "$0")" && pwd)/schema.ckdb"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ "$1" == --compare ]]; then
  [[ -s "${2:-}" ]] || { echo "$usage"; exit 2; }
  cp "$2" "$work/production.ckdb"
else
  TOKEN_FILE="$1"
  [[ -s "$TOKEN_FILE" ]] || { echo "No such file, or it is empty: $TOKEN_FILE"; exit 2; }
  CLOUDKIT_MANAGEMENT_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")" xcrun cktool export-schema \
    --team-id 538SB59LX4 --container-id iCloud.ee.qdo.nook \
    --environment production --output-file "$work/production.ckdb"
fi

# Every record type, and every field as Type.field, one per line.
names() {
  awk '
    /RECORD TYPE/ { type = $3; sub(/\(.*/, "", type); print type; next }
    type == "" { next }
    /^[[:space:]]*\)/ { type = ""; next }
    $1 == "GRANT" || NF == 0 { next }
    { field = $1; gsub(/[",]/, "", field); print type "." field }
  ' "$1" | sort -u
}

names "$schema" > "$work/wanted"
names "$work/production.ckdb" > "$work/have"
missing=$(comm -23 "$work/wanted" "$work/have")
if [[ -n "$missing" ]]; then
  echo "Production lacks these record types and fields from schema.ckdb:"
  sed 's/^/  /' <<< "$missing"
  echo "Import schema.ckdb (scripts/cloudkit/import-schema.sh) and deploy it to production in CloudKit Console before releasing."
  exit 1
fi
echo "Production has every record type and field in schema.ckdb."
