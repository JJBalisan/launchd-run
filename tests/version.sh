#!/bin/bash
#
# Tests for lib/version.sh: the version the wrapper logs at every start.
#
#   bash tests/version.sh
#
# Three cases: REPO_VERSION pins the output (how tests/run.sh keeps its
# transcripts stable), the real checkout gives a git describe string, and a
# copy of the lib outside any repository says "unknown" instead of failing.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO
readonly LIB="${REPO}/lib/version.sh"
failures=0

# Global, not local to main: under bash 3.2 the EXIT trap runs after main's
# locals are gone, and set -u would then abort the cleanup.
SCRATCH=''

#######################################
# Records one assertion.
# Arguments:
#   Description, then the command that must succeed.
#######################################
check() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'ok    %s\n' "${desc}"
  else
    printf 'FAIL  %s\n' "${desc}"
    failures=$((failures + 1))
  fi
}

equal() { [[ "$1" == "$2" ]]; }
matches() { [[ "$1" =~ $2 ]]; }

#######################################
# Sources a copy of the lib in a fresh bash and prints repo_version.
# Arguments:
#   The lib path, then NAME=value pairs for the environment.
#######################################
version_from() {
  local lib="$1"
  shift
  env -i HOME="${HOME}" PATH=/usr/bin:/bin "$@" /bin/bash -uc \
    ". \"\$1\" && repo_version" _ "${lib}"
}

main() {
  SCRATCH="$(mktemp -d)"
  trap 'command rm -rf "${SCRATCH}"' EXIT

  check "REPO_VERSION pins the output" equal \
    "$(version_from "${LIB}" REPO_VERSION=v9.9.9-test)" "v9.9.9-test"

  # A tag gives v1.2.0-3-gabc1234; before the first tag git describe
  # --always falls back to the bare abbreviated commit. Either may carry
  # -dirty while the tree has local edits.
  check "real checkout: a describe string" matches \
    "$(version_from "${LIB}")" \
    '^(v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-g)?[0-9a-f]{7,}(-dirty)?$'

  # The installed wrapper is a symlink into the checkout; the lib must
  # resolve the link, not the directory the link sits in.
  mkdir -p "${SCRATCH}/bin"
  ln -s "${LIB}" "${SCRATCH}/bin/version.sh"
  check "through a symlink: same answer as the checkout" equal \
    "$(version_from "${SCRATCH}/bin/version.sh")" \
    "$(version_from "${LIB}")"

  mkdir -p "${SCRATCH}/not-a-repo/lib"
  /bin/cp -f "${LIB}" "${SCRATCH}/not-a-repo/lib/version.sh"
  check "outside a repository: unknown, exit 0" equal \
    "$(version_from "${SCRATCH}/not-a-repo/lib/version.sh")" "unknown"

  if [[ "${failures}" -gt 0 ]]; then
    printf '%d check(s) failed\n' "${failures}" >&2
    exit 1
  fi
  echo "all checks passed"
}

main "$@"
