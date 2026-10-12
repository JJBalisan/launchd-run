#!/bin/bash
#
# Test suite for launchd-run.sh.
#
#   bash tests/run.sh          # also runs under /bin/bash 3.2
#
# Hermetic: every case gets its own temporary HOME (which holds both the
# per-label fail counters and the audit log), and a stub osascript sits first
# on PATH and records each call to a file instead of raising a banner. Nothing
# outside the temp directory is written, and no network is used.
#
# Assertions print "ok" or "FAIL". A KNOWN-FAIL pins a defect from the
# 2026-10-05 repo audit that is not fixed yet: it does not fail the run, but if
# it starts passing it prints XPASS and does fail the run (like a strict
# xfail), so whoever lands the fix moves the case into the normal checks.
#
# LAUNCHD_RUN_WRAPPER points the suite at another copy of the wrapper (used to
# check that the tests catch deliberately broken copies). The default is the
# repo's launchd-run.sh.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO
readonly WRAPPER="${LAUNCHD_RUN_WRAPPER:-${REPO}/launchd-run.sh}"
readonly SYS_PATH='/usr/bin:/bin:/usr/sbin:/sbin'

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launchd-run-tests.XXXXXX")" || exit 2
readonly TMP_ROOT
readonly STUB_BIN="${TMP_ROOT}/bin"

passes=0
failures=0
known_fails=0
case_n=0
leftover_pids=''

# Set by new_case and run_wrap.
CASE_HOME=''
CASE_DIR=''
RC=0

#######################################
# Kills any job process a test left behind and removes the temp tree.
#######################################
cleanup() {
  local pid
  for pid in ${leftover_pids}; do
    kill -KILL "${pid}" 2>/dev/null
  done
  /bin/rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

#######################################
# Records one assertion.
# Arguments:
#   Description, then the command that must succeed.
#######################################
check() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'ok          %s\n' "${desc}"
    passes=$((passes + 1))
  else
    printf 'FAIL        %s\n' "${desc}"
    failures=$((failures + 1))
  fi
}

#######################################
# Records an assertion that is expected to fail because of a known defect.
# A pass is reported as XPASS and counts as a failure.
# Arguments:
#   Description, defect reference, then the command that should succeed once
#   the defect is fixed.
#######################################
known_fail() {
  local desc="$1" defect="$2"
  shift 2
  if "$@"; then
    printf 'XPASS       %s [%s] - fixed? move it to check\n' \
      "${desc}" "${defect}"
    failures=$((failures + 1))
  else
    printf 'KNOWN-FAIL  %s [%s]\n' "${desc}" "${defect}"
    known_fails=$((known_fails + 1))
  fi
}

#######################################
# Writes the stub osascript. It appends its argv (one line per call, args
# joined by " | ") to $OSASCRIPT_CALLS and exits with $OSASCRIPT_EXIT.
#######################################
make_stubs() {
  mkdir -p "${STUB_BIN}"
  cat >"${STUB_BIN}/osascript" <<'EOF'
#!/bin/bash
out="${OSASCRIPT_CALLS:?stub osascript: OSASCRIPT_CALLS not set}"
line=''
for arg in "$@"; do
  line="${line:+${line} | }${arg}"
done
printf '%s\n' "${line}" >>"${out}"
exit "${OSASCRIPT_EXIT:-0}"
EOF
  chmod +x "${STUB_BIN}/osascript"
}

#######################################
# Starts a fresh case: a new temp HOME with ~/Library/Logs (as on macOS).
# Globals:
#   CASE_DIR, CASE_HOME
#######################################
new_case() {
  case_n=$((case_n + 1))
  CASE_DIR="${TMP_ROOT}/case${case_n}"
  CASE_HOME="${CASE_DIR}/home"
  mkdir -p "${CASE_HOME}/Library/Logs"
}

#######################################
# Runs the wrapper inside the current case.
# Globals:
#   RC (set to the wrapper's exit status)
# Arguments:
#   Arguments for launchd-run.sh.
# Outputs:
#   Wrapper stdout and stderr go to $CASE_DIR/out and $CASE_DIR/err.
#######################################
run_wrap() {
  env HOME="${CASE_HOME}" PATH="${STUB_BIN}:${SYS_PATH}" \
    OSASCRIPT_CALLS="${CASE_DIR}/osascript.calls" \
    OSASCRIPT_EXIT="${OSASCRIPT_EXIT:-0}" \
    "${WRAPPER}" "$@" >"${CASE_DIR}/out" 2>"${CASE_DIR}/err"
  RC=$?
}

#######################################
# Path of a label's fail counter in the current case.
#######################################
counter_file() {
  printf '%s' "${CASE_HOME}/.local/state/launchd-run/$1/fail-count"
}

#######################################
# Writes a label's fail counter verbatim (no trailing newline).
# Arguments:
#   Label, contents.
#######################################
seed_counter() {
  mkdir -p "${CASE_HOME}/.local/state/launchd-run/$1"
  printf '%s' "$2" >"$(counter_file "$1")"
}

# --- Predicates used by the assertions. -------------------------------------

rc_is() { [ "${RC}" -eq "$1" ]; }

# The counter file holds exactly the given text.
counter_is() {
  local f
  f="$(counter_file "$1")"
  [ -f "${f}" ] && [ "$(cat "${f}")" = "$2" ]
}

counter_absent() { [ ! -e "$(counter_file "$1")" ]; }

calls() {
  local f="${CASE_DIR}/osascript.calls"
  if [ -f "${f}" ]; then
    wc -l <"${f}" | tr -d ' '
  else
    echo 0
  fi
}

calls_are() { [ "$(calls)" -eq "$1" ]; }

# Line N of the osascript record contains the fixed string.
call_has() {
  local n="$1" want="$2" line
  line="$(sed -n "${n}p" "${CASE_DIR}/osascript.calls" 2>/dev/null)"
  case "${line}" in
    *"${want}"*) return 0 ;;
    *) return 1 ;;
  esac
}

audit_has() {
  grep -F -q -- "$1" "${CASE_HOME}/Library/Logs/launchd-run.log" 2>/dev/null
}

audit_lines_are() {
  local f="${CASE_HOME}/Library/Logs/launchd-run.log" n=0
  [ -f "${f}" ] && n="$(wc -l <"${f}" | tr -d ' ')"
  [ "${n}" -eq "$1" ]
}

err_has() { grep -F -q -- "$1" "${CASE_DIR}/err"; }
err_lacks() { ! grep -F -q -- "$1" "${CASE_DIR}/err"; }
err_empty() { [ ! -s "${CASE_DIR}/err" ]; }
out_is() { [ "$(cat "${CASE_DIR}/out")" = "$1" ]; }
path_absent() { [ ! -e "$1" ]; }
state_dir_absent() { [ ! -e "${CASE_HOME}/.local/state/launchd-run" ]; }

# Polls (bash 3.2 has no wait -n) until a file exists, for up to ~5 s.
wait_for_file() {
  local i=0
  while [ ! -s "$1" ] && [ "${i}" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$1" ]
}

# Polls until a pid is gone, for up to ~3 s.
pid_gone() {
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "${i}" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  ! kill -0 "$1" 2>/dev/null
}

# --- Cases. ------------------------------------------------------------------

test_argument_errors() {
  local marker
  echo '# argument errors'

  new_case
  run_wrap
  check 'no arguments: exit 64' rc_is 64
  check 'no arguments: usage on stderr' err_has 'usage: launchd-run.sh LABEL'
  check 'no arguments: no state written' state_dir_absent

  new_case
  run_wrap '' -- /usr/bin/true
  check 'empty label: exit 64' rc_is 64
  check 'empty label: usage on stderr' err_has 'usage: launchd-run.sh LABEL'

  new_case
  marker="${CASE_DIR}/ran"
  run_wrap job --bogus -- /usr/bin/touch "${marker}"
  check 'unknown flag: exit 64' rc_is 64
  check 'unknown flag: named on stderr' \
    err_has 'unexpected argument --bogus'
  check 'unknown flag: command not run' path_absent "${marker}"

  new_case
  marker="${CASE_DIR}/ran"
  run_wrap job /usr/bin/touch "${marker}"
  check 'command without --: exit 64' rc_is 64
  check 'command without --: command not run' path_absent "${marker}"

  new_case
  run_wrap job
  check 'label only: exit 64' rc_is 64
  check 'label only: "no command given"' err_has 'no command given'

  new_case
  run_wrap job --
  check 'label and -- only: exit 64' rc_is 64
  check 'label and -- only: "no command given"' err_has 'no command given'

  new_case
  run_wrap job --after 3
  check '--after N with no command: exit 64' rc_is 64

  new_case
  run_wrap job --after
  known_fail '--after with no value: exit 64 (today: unbound variable, 1)' \
    'audit P2 validate --after' rc_is 64
  known_fail '--after with no value: usage error on stderr' \
    'audit P2 validate --after' err_has 'usage'

  new_case
  run_wrap job --after abc -- /bin/sh -c 'exit 3'
  known_fail '--after abc: rejected with exit 64' \
    'audit P2 validate --after' rc_is 64

  new_case
  seed_counter job 0
  run_wrap job --after 0 -- /usr/bin/true
  known_fail '--after 0: no recovery banner on a clean success' \
    'audit P2 validate --after' calls_are 0
}

test_ok_no_streak() {
  echo '# ok with no streak'
  new_case
  # shellcheck disable=SC2016  # $1 and $2 belong to the job's own sh.
  run_wrap job -- /bin/sh -c 'printf "%s|%s\n" "$1" "$2"; echo to-err >&2' \
    sh 'a b' 'c'
  check 'ok: exit 0' rc_is 0
  check 'ok: stdout passed through, args intact' out_is 'a b|c'
  check 'ok: stderr passed through' err_has 'to-err'
  check 'ok: no banner' calls_are 0
  check 'ok: no counter file' counter_absent job
  check 'ok: audit line "ok ("' audit_has 'ok ('
  check 'ok: audit line carries the label' audit_has ' job '
  check 'ok: exactly one audit line' audit_lines_are 1
}

test_fail_threshold() {
  echo '# failures below and at the threshold (default --after 2)'
  new_case
  run_wrap job -- /bin/sh -c 'exit 3'
  check 'fail 1: exit code 3 passed through' rc_is 3
  check 'fail 1: counter 1' counter_is job 1
  check 'fail 1: below threshold, no banner' calls_are 0
  check 'fail 1: audit FAILED line' \
    audit_has 'FAILED exit 3 ('
  check 'fail 1: audit shows consecutive: 1' audit_has 'consecutive: 1)'

  run_wrap job -- /bin/sh -c 'exit 3'
  check 'fail 2: exit 3' rc_is 3
  check 'fail 2: counter 2' counter_is job 2
  check 'fail 2: at threshold, one banner' calls_are 1
  check 'fail 2: banner subtitle "Job failing"' \
    call_has 1 'subtitle "Job failing"'
  check 'fail 2: banner text has exit code and streak' \
    call_has 1 'exit 3 on 2 consecutive runs'
  check 'fail 2: banner title names the label' \
    call_has 1 'with title "launchd: job"'
  check 'fail 2: audit records alert sent' audit_has 'alert sent: Job failing'

  run_wrap job -- /bin/sh -c 'exit 5'
  check 'fail 3: exit 5' rc_is 5
  check 'fail 3: counter 3' counter_is job 3
  check 'fail 3: re-raised every run it stays broken' calls_are 2
  check 'fail 3: banner shows latest exit and streak' \
    call_has 2 'exit 5 on 3 consecutive runs'

  echo '# --after 3'
  new_case
  run_wrap job --after 3 -- /bin/sh -c 'exit 7'
  run_wrap job --after 3 -- /bin/sh -c 'exit 7'
  check '--after 3: no banner after 2 failures' calls_are 0
  run_wrap job --after 3 -- /bin/sh -c 'exit 7'
  check '--after 3: banner on 3rd failure' calls_are 1
  check '--after 3: exit 7 passed through' rc_is 7

  echo '# --after 1'
  new_case
  run_wrap job --after 1 -- /bin/sh -c 'exit 2'
  check '--after 1: banner on first failure' calls_are 1

  echo '# labels are independent'
  new_case
  seed_counter other 5
  run_wrap job -- /bin/sh -c 'exit 3'
  check 'labels: new label starts at 1' counter_is job 1
  check 'labels: other label untouched' counter_is other 5
  check 'labels: no banner' calls_are 0

  echo '# osascript failure is logged, exit code unaffected'
  new_case
  seed_counter job 1
  OSASCRIPT_EXIT=1 run_wrap job -- /bin/sh -c 'exit 3'
  check 'osascript fails: job exit 3 still passed through' rc_is 3
  check 'osascript fails: audit says alert FAILED' \
    audit_has 'alert FAILED to send (osascript)'
  check 'osascript fails: counter still advances' counter_is job 2
}

test_recovery() {
  echo '# recovery banner'
  new_case
  seed_counter job 2
  run_wrap job -- /usr/bin/true
  check 'recovery: exit 0' rc_is 0
  check 'recovery: counter cleared' counter_absent job
  check 'recovery: one banner' calls_are 1
  check 'recovery: subtitle "Back to normal"' \
    call_has 1 'subtitle "Back to normal"'
  check 'recovery: text names the streak' \
    call_has 1 'succeeded after 2 failed runs'
  run_wrap job -- /usr/bin/true
  check 'recovery: next success raises nothing' calls_are 1

  new_case
  seed_counter job 1
  run_wrap job -- /usr/bin/true
  check 'recovery below threshold: no banner' calls_are 0
  check 'recovery below threshold: counter cleared' counter_absent job

  echo '# full cycle: fail, fail (alert), ok (recovery)'
  new_case
  run_wrap job -- /bin/sh -c 'exit 4'
  run_wrap job -- /bin/sh -c 'exit 4'
  run_wrap job -- /usr/bin/true
  check 'cycle: two banners in total' calls_are 2
  check 'cycle: second banner is the recovery' \
    call_has 2 'succeeded after 2 failed runs'
  check 'cycle: counter cleared' counter_absent job
  check 'cycle: three audit lines plus two alert lines' audit_lines_are 5
}

test_stop_signals() {
  local sig
  echo '# stop signals 129/130/137/143 are not failures'
  for sig in 129 130 137 143; do
    new_case
    seed_counter job 1
    run_wrap job -- /bin/sh -c "exit ${sig}"
    check "exit ${sig}: passed through" rc_is "${sig}"
    check "exit ${sig}: streak of 1 preserved" counter_is job 1
    check "exit ${sig}: no banner" calls_are 0
    check "exit ${sig}: audit says not counted" \
      audit_has "stopped by signal (exit ${sig}, "

    new_case
    run_wrap job -- /bin/sh -c "exit ${sig}"
    check "exit ${sig} with no streak: no counter created" counter_absent job
  done

  new_case
  seed_counter job 2
  run_wrap job -- /bin/sh -c 'exit 143'
  check 'stop at threshold: streak of 2 preserved' counter_is job 2
  check 'stop at threshold: no recovery banner' calls_are 0
  run_wrap job -- /usr/bin/true
  check 'stop then ok: recovery reports the preserved streak' \
    call_has 1 'succeeded after 2 failed runs'

  new_case
  seed_counter job 1
  run_wrap job -- /bin/sh -c 'kill -TERM $$'
  check 'child really killed by SIGTERM: exit 143' rc_is 143
  check 'child really killed by SIGTERM: streak preserved' counter_is job 1
  check 'child really killed by SIGTERM: not counted' \
    audit_has 'stopped by signal (exit 143'
}

test_crash_signals() {
  local sig
  echo '# crash signals 134/138/139 are failures'
  for sig in 134 138 139; do
    new_case
    seed_counter job 1
    run_wrap job -- /bin/sh -c "exit ${sig}"
    check "exit ${sig}: passed through" rc_is "${sig}"
    check "exit ${sig}: counter 1 -> 2" counter_is job 2
    check "exit ${sig}: banner at threshold" calls_are 1
    check "exit ${sig}: banner names the exit code" \
      call_has 1 "exit ${sig} on 2 consecutive runs"
    check "exit ${sig}: audit FAILED line" audit_has "FAILED exit ${sig} ("
  done
}

test_bad_counter_file() {
  local content
  echo '# empty counter file'
  new_case
  seed_counter job ''
  run_wrap job -- /usr/bin/true
  check 'empty counter, ok: exit 0' rc_is 0
  check 'empty counter, ok: counter removed' counter_absent job
  check 'empty counter, ok: no banner' calls_are 0
  known_fail 'empty counter, ok: no "[: integer expression" on stderr' \
    'audit P2 validate fail-count' err_lacks 'integer expression expected'

  new_case
  seed_counter job ''
  run_wrap job -- /bin/sh -c 'exit 3'
  check 'empty counter, fail: exit 3' rc_is 3
  check 'empty counter, fail: counter restarts at 1' counter_is job 1
  check 'empty counter, fail: no banner' calls_are 0
  check 'empty counter, fail: no error noise' err_empty

  echo '# garbage counter file'
  for content in garbage 12abc; do
    new_case
    seed_counter job "${content}"
    run_wrap job -- /usr/bin/true
    check "counter '${content}', ok: exit 0" rc_is 0
    check "counter '${content}', ok: counter removed" counter_absent job
    check "counter '${content}', ok: no banner" calls_are 0
    known_fail "counter '${content}', ok: no error on the job's stderr" \
      'audit P2 validate fail-count' err_lacks 'integer expression expected'

    new_case
    seed_counter job "${content}"
    run_wrap job -- /bin/sh -c 'exit 3'
    if [ "${content}" = garbage ]; then
      # A word reads as an unset variable in $(( )); set -u aborts the
      # wrapper with exit 1. A bad number only fails the expansion.
      known_fail "counter '${content}', fail: job exit 3 passed through" \
        'audit P2 validate fail-count' rc_is 3
    else
      check "counter '${content}', fail: job exit 3 passed through" rc_is 3
    fi
    known_fail "counter '${content}', fail: counter reset to 1" \
      'audit P2 validate fail-count' counter_is job 1
    known_fail "counter '${content}', fail: FAILED audit line written" \
      'audit P2 validate fail-count' audit_has 'FAILED exit 3'
  done
}

test_signal_to_wrapper() {
  local job pidfile wpid wrc child=''
  echo '# stop signal sent to the wrapper itself (launchctl kill, bootout)'
  new_case
  seed_counter svc 1
  job="${CASE_DIR}/job.sh"
  pidfile="${CASE_DIR}/child.pid"
  # shellcheck disable=SC2016  # Expanded by the job script, not here.
  printf '#!/bin/sh\necho $$ >"$1"\nexec /bin/sleep 30\n' >"${job}"
  chmod +x "${job}"

  # env execs the wrapper, so $! is the wrapper's own bash. SIGTERM, not
  # SIGINT: a non-interactive shell starts async jobs with SIGINT ignored.
  env HOME="${CASE_HOME}" PATH="${STUB_BIN}:${SYS_PATH}" \
    OSASCRIPT_CALLS="${CASE_DIR}/osascript.calls" \
    "${WRAPPER}" svc -- "${job}" "${pidfile}" \
    >"${CASE_DIR}/out" 2>"${CASE_DIR}/err" &
  wpid=$!

  if ! wait_for_file "${pidfile}"; then
    check 'wrapper started the job' false
    kill -KILL "${wpid}" 2>/dev/null
    wait "${wpid}" 2>/dev/null
    return
  fi
  child="$(cat "${pidfile}")"
  leftover_pids="${leftover_pids} ${child}"

  kill -TERM "${wpid}"
  # The braces keep bash's "Terminated" job report out of the test output.
  { wait "${wpid}"; } 2>/dev/null
  wrc=$?
  RC="${wrc}"

  check 'SIGTERM to wrapper: exits 143' rc_is 143
  check 'SIGTERM to wrapper: streak of 1 untouched' counter_is svc 1
  check 'SIGTERM to wrapper: no banner' calls_are 0
  known_fail 'SIGTERM to wrapper: stop recorded in the audit log' \
    'audit P1 trap and forward HUP/INT/TERM' \
    audit_has 'stopped by signal'
  known_fail 'SIGTERM to wrapper: forwarded, job not orphaned' \
    'audit P1 trap and forward HUP/INT/TERM' pid_gone "${child}"
}

main() {
  if [ ! -x "${WRAPPER}" ]; then
    echo "run.sh: wrapper not found or not executable: ${WRAPPER}" >&2
    exit 2
  fi
  make_stubs
  # Never let a real banner through: the stub must win the PATH lookup.
  if [ "$(PATH="${STUB_BIN}:${SYS_PATH}" command -v osascript)" \
    != "${STUB_BIN}/osascript" ]; then
    echo 'run.sh: stub osascript is not first on PATH; aborting' >&2
    exit 2
  fi

  echo "launchd-run tests (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_argument_errors
  test_ok_no_streak
  test_fail_threshold
  test_recovery
  test_stop_signals
  test_crash_signals
  test_bad_counter_file
  test_signal_to_wrapper

  printf '\n%d passed, %d failed, %d known-fail\n' \
    "${passes}" "${failures}" "${known_fails}"
  [ "${failures}" -eq 0 ]
}

main "$@"
