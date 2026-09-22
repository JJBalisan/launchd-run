#!/bin/bash
# Symlinks launchd-run.sh into ~/.local/bin. Wrapping a job is a separate step:
# put the wrapper in front of the job's existing ProgramArguments, e.g.
#   [launchd-run.sh, <label>, --after, 2, --, /bin/bash, /path/to/job.sh]
# then bootout + bootstrap that agent.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.local/bin"
ln -sfn "$REPO/launchd-run.sh" "$HOME/.local/bin/launchd-run.sh"
ls -la "$HOME/.local/bin/launchd-run.sh"
