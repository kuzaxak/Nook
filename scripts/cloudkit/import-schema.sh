#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Imports scripts/cloudkit/schema.ckdb, the record types space sync uses, into the development
# environment of the iCloud.ee.qdo.nook container:
#   scripts/cloudkit/import-schema.sh path/to/management-token
#
# The file holds a CloudKit management token (CloudKit Console → Settings → Tokens & Keys); it is
# saved for cktool and never printed. Developer ID builds use the production environment, so
# deploy the imported schema there afterwards in CloudKit Console: Deploy Schema Changes.
set -euo pipefail
cd "$(dirname "$0")"

TOKEN_FILE="${1:?usage: scripts/cloudkit/import-schema.sh path/to/management-token}"
[[ -s "$TOKEN_FILE" ]] || { echo "No such file, or it is empty: $TOKEN_FILE"; exit 1; }

xcrun cktool save-token --type management --force "$(tr -d '[:space:]' < "$TOKEN_FILE")" > /dev/null
xcrun cktool import-schema --team-id 538SB59LX4 --container-id iCloud.ee.qdo.nook \
  --environment development --validate --file schema.ckdb
echo "Imported schema.ckdb into development. Deploy it to production in CloudKit Console."
