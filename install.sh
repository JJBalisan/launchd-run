#!/bin/bash
#
# Symlinks launchd-run.sh into ~/.local/bin. Wrapping a job is a separate step:
# put the wrapper in front of the job's existing ProgramArguments, e.g.
#   [launchd-run.sh, <label>, --after, 2, --, /bin/bash, /path/to/job.sh]
# then bootout + bootstrap that agent.
#
# The link points into this checkout, so after this a `git pull` here is the
# deployment; the version printed is what the next run will log.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO
readonly BIN_DIR="${HOME}/.local/bin"

# shellcheck source=lib/version.sh
. "${REPO}/lib/version.sh" 2>/dev/null \
  || repo_version() { echo "${REPO_VERSION:-unknown}"; }

main() {
  mkdir -p "${BIN_DIR}"
  ln -sfn "${REPO}/launchd-run.sh" "${BIN_DIR}/launchd-run.sh"
  ls -la "${BIN_DIR}/launchd-run.sh"
  echo "installed launchd-run $(repo_version)"
}

main "$@"
