#!/bin/bash
#
# Checks for issue #58 (a missing ~/Library/Logs). Loads the harness from
# run.sh without running its suite.
#
#   bash tests/lr_52_58.sh     # also under /bin/bash 3.2

# The harness globals come from the eval, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
eval "$(/usr/bin/sed '/^main "\$@"$/d' "$(dirname "$0")/run.sh")"

# Lines of the case's stderr that contain a fixed string.
lr58_err_count() { grep -F -c -- "$1" "${CASE_DIR}/err"; }
lr58_err_lines_are() { [ "$(lr_stop_lines "${CASE_DIR}/err")" -eq "$1" ]; }
lr58_err_has_once() { [ "$(lr58_err_count "$1")" -eq 1 ]; }
lr58_first_err_is() { [ "$(sed -n 1p "${CASE_DIR}/err")" = "$1" ]; }

# A home without ~/Library/Logs (a fresh account, a HOME that is not a macOS
# home): the wrapper makes the directory and logs the run, and the job's
# stderr gets nothing from it.
test_lr58_missing_logs_dir() {
  echo '# lr-58: a HOME without Library/Logs'
  new_case
  /bin/rm -rf "${CASE_HOME}/Library"
  run_wrap svc -- /bin/sh -c 'echo job-err >&2; exit 1'
  check 'lr-58: no Logs dir: exits with the job'"'"'s 1' rc_is 1
  check 'lr-58: no Logs dir: the job'"'"'s stderr is all there is' \
    lr58_err_lines_are 1
  check 'lr-58: no Logs dir: the job'"'"'s own line kept' \
    lr58_first_err_is job-err
  check 'lr-58: no Logs dir: start line logged' audit_has 'started: '
  check 'lr-58: no Logs dir: failure logged' \
    audit_has 'FAILED exit 1 ('
  check 'lr-58: no Logs dir: counted' counter_is svc 1

  new_case
  /bin/rm -rf "${CASE_HOME}/Library"
  run_wrap svc -- /usr/bin/true
  check 'lr-58: no Logs dir, ok run: exits 0' rc_is 0
  check 'lr-58: no Logs dir, ok run: stderr empty' err_empty
  check 'lr-58: no Logs dir, ok run: logged' audit_has 'ok ('
}

# A Logs directory that cannot be made (here ~/Library is a file): no bash
# error reaches the job's stderr, but one line from the wrapper says that the
# run is not in the audit log. The counter still works.
test_lr58_unwritable_log() {
  echo '# lr-58: an audit log that cannot be written'
  new_case
  /bin/rm -rf "${CASE_HOME}/Library"
  echo 'not a directory' >"${CASE_HOME}/Library"
  run_wrap svc -- /bin/sh -c 'echo job-err >&2; exit 1'
  check 'lr-58: unwritable: exits with the job'"'"'s 1' rc_is 1
  check 'lr-58: unwritable: the job'"'"'s own line comes first' \
    lr58_first_err_is job-err
  check 'lr-58: unwritable: one warning from the wrapper' \
    lr58_err_has_once 'launchd-run: cannot write the audit log'
  check 'lr-58: unwritable: the warning names the log' \
    err_has "${CASE_HOME}/Library/Logs/launchd-run.log"
  check 'lr-58: unwritable: nothing else on stderr' lr58_err_lines_are 2
  check 'lr-58: unwritable: still counted' counter_is svc 1
}

main() {
  make_stubs
  echo "lr-52/58 checks (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_lr58_missing_logs_dir
  test_lr58_unwritable_log
  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
