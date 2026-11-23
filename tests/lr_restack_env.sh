#!/bin/bash
#
# Checks added when the review fixes of #56 were merged into this branch:
# the three locals those fixes gave main (stop_pid, told, next_wait) must,
# like every other wrapper name, leave a caller variable of the same name
# untouched for the job (#23). Loads the harness from run.sh without
# running its suite.
#
#   bash tests/lr_restack_env.sh     # also under /bin/bash 3.2

# The harness globals come from the eval, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
eval "$(/usr/bin/sed '/^main "\$@"$/d' "$(dirname "$0")/run.sh")"

# Names of main's locals added by the #56 review fixes.
readonly RESTACK_NAMES='stop_pid told next_wait'

# The job wrote "<name>=<value>" for the name given.
restack_job_saw() {
  grep -qx "$1=caller" "${CASE_DIR}/seen"
}

test_restack_names_reach_job() {
  local name
  echo '# restack: the caller'"'"'s copies of the new locals reach the job'
  for name in ${RESTACK_NAMES}; do
    new_case
    # shellcheck disable=SC2016  # $1 and $2 belong to the job's shell.
    env "${name}=caller" /bin/bash -c '
      cd "$1" || exit 1
      shift
      "$@"' restack "${CASE_DIR}" \
      env HOME="${CASE_HOME}" PATH="${STUB_BIN}:${SYS_PATH}" \
      OSASCRIPT_CALLS="${CASE_DIR}/osascript.calls" \
      REPO_VERSION="${TEST_VERSION}" \
      "${WRAPPER}" job -- /bin/sh -c \
      'printf "%s=%s\n" "$1" "$(printenv "$1")" >"$2"' restack \
      "${name}" "${CASE_DIR}/seen" >"${CASE_DIR}/out" 2>"${CASE_DIR}/err"
    RC=$?
    check "restack: the caller's ${name} reaches the job" \
      restack_job_saw "${name}"
    check "restack: ${name} case exits 0" rc_is 0
  done
}

main() {
  make_stubs
  echo "restack checks (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_restack_names_reach_job
  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
