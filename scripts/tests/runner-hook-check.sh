#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Runs scripts/runner/job-started-hook.sh the way the runner does: `bash -e <hook>` as a child of
# Runner.Worker, after which the job's `if: always()` steps still run.
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cp /bin/bash "$test_dir/Runner.Worker"
hook="$PWD/scripts/runner/job-started-hook.sh"
release=kuzaxak/Nook/.github/workflows/release.yml

# job runs|refused <description> [NAME=value ...]
job() {
  local expected="$1" description="$2" status=0
  shift 2
  # shellcheck disable=SC2016
  env -i PATH=/usr/bin:/bin "$@" "$test_dir/Runner.Worker" -c 'bash -e "$0"; echo "steps ran"' "$hook" < /dev/null \
    > "$test_dir/out" 2>&1 || status=$?
  if [[ "$expected" == runs ]]; then
    if [[ "$status" != 0 ]] || ! grep -qx "steps ran" "$test_dir/out"; then
      echo "FAIL: $description was refused: $(<"$test_dir/out")"; exit 1
    fi
  elif grep -qx "steps ran" "$test_dir/out"; then
    echo "FAIL: $description ran its steps: $(<"$test_dir/out")"; exit 1
  fi
}

job runs "tag push of release.yml" \
  GITHUB_WORKFLOW_REF="$release@refs/tags/v1.5.3" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1.5.3
job runs "workflow_dispatch of release.yml" \
  GITHUB_WORKFLOW_REF="$release@refs/heads/develop" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/develop
job refused "pull_request of release.yml" \
  GITHUB_WORKFLOW_REF="$release@refs/pull/7/merge" GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/7/merge
job refused "push of release.yml to a branch" \
  GITHUB_WORKFLOW_REF="$release@refs/heads/develop" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/develop
job refused "another workflow on a tag" \
  GITHUB_WORKFLOW_REF="kuzaxak/Nook/.github/workflows/macos-build.yml@refs/tags/v1.5.3" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1.5.3
job refused "a job without the variables"

echo "runner hook check passed"
