# shellcheck shell=bash
# Names the checkout a program runs from. Copy it into a repo and source it.
#
# The house deploys by `git pull` (installed scripts are symlinks into the
# checkout), so the only honest version is what git says about the working
# tree at run time. Every entry point logs it as its first line, so a log
# can always be matched to the code that wrote it, including an unmerged
# branch left checked out or local edits (`-dirty`).
#
# Releases are annotated tags vX.Y.Z (README, "Releasing"), so the output
# is `v1.2.0-0-gabc1234` on a release, `v1.2.0-3-gdef5678` three commits
# past it, `abc1234` before the first tag, with `-dirty` appended when the
# tree has local changes, or `unknown` when git cannot answer.
#
# git is called by absolute path: launchd and cron give jobs a minimal
# PATH. /usr/bin/git on this Mac resolves through a full Xcode, so there is
# no command-line-tools install dialog for a background job to hang on.
#
# Copying it: this file lives one directory below the repo root (lib/,
# templates/, tests/). Edit the `/..` in REPO_ROOT below when the copy lives
# at the root or deeper. Source it before any `cd`, with the script's own
# path resolved through symlinks, and log the line first:
#
#   lib="$(dirname "$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")")/../lib"
#   [[ -r "${lib}/version.sh" ]] && . "${lib}/version.sh"
#   ...
#   log "<repo> $(repo_version)"    # the first line of every run
#
# REPO_VERSION, when set in the environment, is printed as is; tests pin it
# so their transcripts stay stable.

REPO_ROOT="$(cd "$(dirname "$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")")/.." \
  && pwd)"
readonly REPO_ROOT

#######################################
# Prints the version of the checkout this file lives in.
# Globals:
#   REPO_ROOT
#   REPO_VERSION - when set, printed as is.
# Outputs:
#   One line: the git describe string, or "unknown".
# Returns:
#   0 always.
#######################################
repo_version() {
  local v
  if [[ -n "${REPO_VERSION:-}" ]]; then
    printf '%s\n' "${REPO_VERSION}"
    return 0
  fi
  v="$(/usr/bin/git -C "${REPO_ROOT}" describe --tags --long --dirty \
    --always 2>/dev/null)" && [[ -n "${v}" ]] || v="unknown"
  printf '%s\n' "${v}"
  return 0
}
