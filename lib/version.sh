# shellcheck shell=bash
# Sourced by launchd-run.sh and install.sh: names the checkout a run comes
# from.
#
# The installed wrapper is a symlink into this checkout and "deploy" is a
# git pull, so the only honest version is what git says about the working
# tree at run time. The wrapper logs it on every run's start line, so an
# audit line can always be matched to the code that wrote it, including an
# unmerged branch left checked out or local edits (`-dirty`).
#
# Releases are annotated tags vX.Y.Z (see README "Releasing"), so the
# output is `v1.0.0-0-gabc1234` on a release, `v1.0.0-3-gdef5678` three
# commits past it, `abc1234` before the first tag, with `-dirty` appended
# when the tree has local changes, or `unknown` when git cannot answer.
#
# git is called by absolute path: launchd gives jobs a minimal PATH. It is
# /usr/bin/git, which on this Mac resolves through a full Xcode, so there is
# no command-line-tools install dialog for a background job to hang on.
#
# Usage, from a script (before any `cd`, so the path still resolves):
#   LIB="$(dirname "$(/usr/bin/readlink -f "$0")")/lib/version.sh"
#   . "${LIB}" 2>/dev/null \
#     || repo_version() { echo "${REPO_VERSION:-unknown}"; }
#   ...
#   note "started: launchd-run $(repo_version)"

# readlink -f follows the installed symlink back into the checkout, so a
# copy of this file sourced through ~/.local/bin still names the repo.
REPO_ROOT="$(dirname "$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")")/.."
REPO_ROOT="$(cd "${REPO_ROOT}" && pwd)"
readonly REPO_ROOT

#######################################
# Prints the version of the checkout this file lives in.
# Globals:
#   REPO_ROOT
#   REPO_VERSION - when set, printed as is (tests pin it to a fixed string).
# Outputs:
#   One line: the git describe string, or "unknown".
# Returns:
#   Always 0.
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
