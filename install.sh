#!/bin/bash
#
# Symlinks launchd-run.sh into ~/.local/bin. Wrapping a job is a separate step:
# put the wrapper in front of the job's existing ProgramArguments, e.g.
#   [launchd-run.sh, <label>, --after, 2, --, /bin/bash, /path/to/job.sh]
# then bootout + bootstrap that agent.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO
readonly BIN_DIR="${HOME}/.local/bin"

mkdir -p "${BIN_DIR}"
ln -sfn "${REPO}/launchd-run.sh" "${BIN_DIR}/launchd-run.sh"
ls -la "${BIN_DIR}/launchd-run.sh"
