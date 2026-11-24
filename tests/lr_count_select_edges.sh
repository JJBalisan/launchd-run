#!/bin/bash
#
# Selector's extra checks for the lr-count lane (#45, #46, #48): the edges
# of the 9-digit limits, more labels that would leave the state directory,
# and the reset of an unremovable counter at other --after values. Loads
# the harness from run.sh without running its suite.
#
#   bash tests/lr_count_select_edges.sh     # also under /bin/bash 3.2

# The harness globals come from the eval, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
eval "$(/usr/bin/sed '/^main "\$@"$/d' "$(dirname "$0")/run.sh")"

# Makes a label's state directory read-only so the counter cannot be
# removed. Returns 1 (and prints a skip line) if it is still writable.
sel_lock_dir() {
  local dir="${CASE_HOME}/.local/state/launchd-run/$1"
  chmod a-w "${dir}"
  if : 2>/dev/null >"${dir}/probe"; then
    printf 'skip        %s\n' "select: ${dir##*/} is still writable"
    chmod u+w "${dir}"
    return 1
  fi
}

sel_unlock_dir() { chmod u+w "${CASE_HOME}/.local/state/launchd-run/$1"; }

# The audit log has exactly one line holding the fixed string.
sel_audit_count() {
  local n
  n="$(grep -F -c -- "$1" "${CASE_HOME}/Library/Logs/launchd-run.log" \
    2>/dev/null)"
  [ "${n:-0}" -eq "$2" ]
}

# No file or directory was created anywhere under the case directory but
# the HOME's empty Library/Logs.
sel_nothing_written() {
  local n
  n="$(find "${CASE_DIR}" -mindepth 1 -type f ! -name err ! -name out \
    | wc -l | tr -d ' ')"
  [ "${n}" -eq 0 ] && state_dir_absent
}

test_sel_45() {
  local value marker
  echo '# select #45: the 9-digit limit on --after and the counter'
  for value in 0999999999 1000000000000000000000000000000; do
    new_case
    marker="${CASE_DIR}/ran"
    run_wrap job --after "${value}" -- /usr/bin/touch "${marker}"
    check "select: #45 --after ${value}: exit 64" rc_is 64
    check "select: #45 --after ${value}: not run" path_absent "${marker}"
  done

  # The usage error names --after, and so tells it from --kill-after.
  new_case
  run_wrap job --kill-after 5 --after 1000000000 -- /usr/bin/true
  check 'select: #45 --after 10 digits after --kill-after: exit 64' rc_is 64
  check 'select: #45 that message names --after' \
    lr_count_err_line_has '--after' '1000000000'

  # The largest streak the wrapper keeps: the next failure writes ten
  # digits, which still compares right; the one after starts over.
  new_case
  seed_counter job 999999999
  run_wrap job --after 999999999 -- /bin/sh -c 'exit 4'
  check 'select: #45 999999999 + 1 failure: exit 4' rc_is 4
  check 'select: #45 999999999 + 1 failure: banner' \
    lr_count_calls_with 'Job failing' 1
  run_wrap job --after 999999999 -- /bin/sh -c 'exit 4'
  check 'select: #45 10-digit stored count, fail: counter 1' counter_is job 1
  check 'select: #45 10-digit stored count, fail: no new banner' \
    lr_count_calls_with 'Job failing' 1

  # A 10-digit corrupt counter with a success: removed, no recovery.
  new_case
  seed_counter job 5000000000
  run_wrap job --after 1 -- /usr/bin/true
  check 'select: #45 10-digit counter, ok, --after 1: no banner' calls_are 0
  check 'select: #45 10-digit counter, ok: counter removed' counter_absent job

  # Nine digits with a leading zero is still corrupt (octal).
  new_case
  seed_counter job 012345678
  run_wrap job -- /bin/sh -c 'exit 3'
  check 'select: #45 counter 012345678, fail: counter 1' counter_is job 1
}

test_sel_46() {
  local label marker
  echo '# select #46: more labels that would leave the state directory'
  for label in '..x' '.hidden' 'a/../b' '//' 'x/' '/' 'job/.' '.a.b'; do
    new_case
    marker="${CASE_DIR}/ran"
    run_wrap "${label}" -- /usr/bin/touch "${marker}"
    check "select: #46 label '${label}': exit 64" rc_is 64
    check "select: #46 label '${label}': not run" path_absent "${marker}"
    check "select: #46 label '${label}': nothing written" sel_nothing_written
  done

  # Refused even when the rest of the command line is valid and asks for
  # more, and when the command would succeed.
  new_case
  marker="${CASE_DIR}/ran"
  run_wrap a/b --after 1 --kill-after 3 -- /usr/bin/touch "${marker}"
  check 'select: #46 a/b with options: exit 64' rc_is 64
  check 'select: #46 a/b with options: not run' path_absent "${marker}"
  check 'select: #46 a/b with options: nothing written' sel_nothing_written

  # An empty HOME is HOME unset: still refused.
  new_case
  marker="${CASE_DIR}/ran"
  env HOME='' PATH="${STUB_BIN}:${SYS_PATH}" \
    OSASCRIPT_CALLS="${CASE_DIR}/osascript.calls" \
    "${WRAPPER}" .job -- /usr/bin/touch "${marker}" \
    >"${CASE_DIR}/out" 2>"${CASE_DIR}/err"
  RC=$?
  check "select: #46 empty HOME, label '.job': exit 64" rc_is 64
  check "select: #46 empty HOME, label '.job': not run" path_absent "${marker}"

  # Dots inside or at the end, dashes and the like still work.
  for label in 'a.b.c' 'job..' 'x-y_z' 'a b'; do
    new_case
    run_wrap "${label}" -- /bin/sh -c 'exit 3'
    check "select: #46 label '${label}': accepted, exit 3" rc_is 3
    check "select: #46 label '${label}': counted" counter_is "${label}" 1
  done
}

test_sel_48() {
  echo '# select #48: reset of an unremovable counter, other --after values'
  # prev below --after: reset, no banner, then a fresh streak from 1.
  new_case
  seed_counter job 2
  if sel_lock_dir job; then
    run_wrap job --after 3 -- /usr/bin/true
    check 'select: #48 2 of --after 3, ok: counter 0' counter_is job 0
    check 'select: #48 2 of --after 3, ok: no banner' calls_are 0
    check 'select: #48 2 of --after 3, ok: reset noted' lr_count_reset_noted
    check 'select: #48 2 of --after 3, ok: one outcome line' \
      sel_audit_count 'cannot clear' 1
    check 'select: #48 2 of --after 3, ok: two audit lines' audit_lines_are 2
    run_wrap job --after 3 -- /bin/sh -c 'exit 3'
    run_wrap job --after 3 -- /bin/sh -c 'exit 3'
    check 'select: #48 then two failures: counter 2' counter_is job 2
    check 'select: #48 then two failures: no banner' calls_are 0
    run_wrap job --after 3 -- /bin/sh -c 'exit 3'
    check 'select: #48 then a third: counter 3' counter_is job 3
    check 'select: #48 then a third: one failing banner' \
      lr_count_calls_with 'Job failing' 1
    run_wrap job --after 3 -- /usr/bin/true
    check 'select: #48 then ok: back to normal once' \
      lr_count_calls_with 'Back to normal' 1
    check 'select: #48 then ok: counter 0' counter_is job 0
    run_wrap job --after 3 -- /usr/bin/true
    check 'select: #48 ok again at 0: no new banner' calls_are 2
    check 'select: #48 ok again at 0: counter 0' counter_is job 0
    check 'select: #48 ok again at 0: exit 0' rc_is 0
    check 'select: #48 ok again at 0: job stderr empty' err_empty
    sel_unlock_dir job
  fi

  # prev exactly at --after: banner names the streak.
  new_case
  seed_counter job 3
  if sel_lock_dir job; then
    run_wrap job --after 3 -- /usr/bin/true
    check 'select: #48 3 of --after 3, ok: one banner' calls_are 1
    check 'select: #48 3 of --after 3, ok: banner text' \
      call_has 1 'succeeded after 3 failed runs'
    check 'select: #48 3 of --after 3, ok: counter 0' counter_is job 0
    sel_unlock_dir job
  fi

  # A corrupt counter that cannot be removed: reset, no banner.
  new_case
  seed_counter job 'garbage'
  if sel_lock_dir job; then
    run_wrap job --after 1 -- /usr/bin/true
    check 'select: #48 corrupt, unremovable, ok: no banner' calls_are 0
    check 'select: #48 corrupt, unremovable, ok: counter 0' counter_is job 0
    sel_unlock_dir job
  fi

  # The counter is a directory: neither removable nor writable.
  new_case
  mkdir -p "$(counter_file job)"
  run_wrap job --after 1 -- /usr/bin/true
  check 'select: #48 counter is a dir, ok: exit 0' rc_is 0
  check 'select: #48 counter is a dir, ok: no banner' calls_are 0
  check 'select: #48 counter is a dir, ok: cannot clear' \
    audit_has 's) - cannot clear'
  check 'select: #48 counter is a dir, ok: no reset noted' lr_count_no_reset
  check 'select: #48 counter is a dir, ok: job stderr empty' err_empty

  # A plain success with a removable counter keeps today's line.
  new_case
  seed_counter job 4
  run_wrap job -- /usr/bin/true
  check 'select: #48 removable: plain ok line' audit_lacks 'cannot clear'
  check 'select: #48 removable: no reset text' audit_lacks 'reset'
  check 'select: #48 removable: counter removed' counter_absent job
  check 'select: #48 removable: one banner' calls_are 1
}

main() {
  make_stubs
  echo "lr-count select checks (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_sel_45
  test_sel_46
  test_sel_48
  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
