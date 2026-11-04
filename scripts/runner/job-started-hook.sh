#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Job-started hook of the self-hosted nook-release runner: the runner takes only
# .github/workflows/release.yml of kuzaxak/Nook, for a v* tag push or workflow_dispatch. Installed
# outside the runner's work directory:
#   cp scripts/runner/job-started-hook.sh ~/actions-runner-nook/hooks/job-started.sh
#   chmod 755 ~/actions-runner-nook/hooks/job-started.sh
#   echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$HOME/actions-runner-nook/hooks/job-started.sh" >> ~/actions-runner-nook/.env
#   cd ~/actions-runner-nook && ./svc.sh stop && ./svc.sh start
set -euo pipefail

allowed() {
  [[ "${GITHUB_WORKFLOW_REF:-}" == kuzaxak/Nook/.github/workflows/release.yml@* ]] || return 1
  case "${GITHUB_EVENT_NAME:-}" in
    push) [[ "${GITHUB_REF:-}" == refs/tags/v* ]] ;;
    workflow_dispatch) return 0 ;;
    *) return 1 ;;
  esac
}

allowed && exit 0

echo "nook-release refuses this job: ${GITHUB_WORKFLOW_REF:-no workflow} (${GITHUB_EVENT_NAME:-no event} ${GITHUB_REF:-no ref})"
# The runner runs this hook as a step with if: always(), so a failed hook still lets the job's
# if: always() steps run; the job ends only when its Runner.Worker does.
if [[ "$(ps -o comm= -p "$PPID")" == */Runner.Worker ]]; then kill -KILL "$PPID"; fi
exit 1
