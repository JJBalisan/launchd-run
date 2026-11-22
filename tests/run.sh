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
# Assertions print "ok" or "FAIL".
#
# LAUNCHD_RUN_WRAPPER points the suite at another copy of the wrapper (used to
# check that the tests catch deliberately broken copies). The default is the
# repo's launchd-run.sh.
#
# The wrapper logs the checkout's version (lib/version.sh) on every start
# line; the suite pins it to vTEST so the transcripts do not depend on git.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO
readonly WRAPPER="${LAUNCHD_RUN_WRAPPER:-${REPO}/launchd-run.sh}"
readonly SYS_PATH='/usr/bin:/bin:/usr/sbin:/sbin'
readonly TEST_VERSION='vTEST'

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launchd-run-tests.XXXXXX")" || exit 2
readonly TMP_ROOT
readonly STUB_BIN="${TMP_ROOT}/bin"

passes=0
failures=0
case_n=0
leftover_pids=''

# Set by new_case and run_wrap.
CASE_HOME=''
CASE_DIR=''
RC=0
# Read by launchd_stop: a SECONDS for the wrapper to inherit, if not empty.
WRAPPER_SECONDS=''

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
    OSASCRIPT_EXIT="${OSASCRIPT_EXIT:-0}" REPO_VERSION="${TEST_VERSION}" \
    "${WRAPPER}" "$@" >"${CASE_DIR}/out" 2>"${CASE_DIR}/err"
  RC=$?
}

#######################################
# Like run_wrap, but through perl's system(), which (unlike the shell's $?)
# tells a process killed by signal N from one that exited 128+N, as launchd
# does. Runs in $CASE_DIR, so a job's core or stackdump lands there.
# Globals:
#   RC (set to the exit status, or 128+N when killed by signal N)
#   KILLED_BY (set to the signal number that killed the wrapper, or 0)
# Arguments:
#   Arguments for launchd-run.sh.
#######################################
run_wrap_raw() {
  # shellcheck disable=SC2016  # $? and $f belong to perl.
  (cd "${CASE_DIR}" \
    && env HOME="${CASE_HOME}" PATH="${STUB_BIN}:${SYS_PATH}" \
      OSASCRIPT_CALLS="${CASE_DIR}/osascript.calls" \
      REPO_VERSION="${TEST_VERSION}" \
      /usr/bin/perl -e 'my $f = shift; system(@ARGV);
        open(my $h, ">", $f) or die; print $h ($? & 127);
        exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' \
      "${CASE_DIR}/killed-by" "${WRAPPER}" "$@" \
      >"${CASE_DIR}/out" 2>"${CASE_DIR}/err")
  RC=$?
  KILLED_BY="$(cat "${CASE_DIR}/killed-by" 2>/dev/null)"
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

audit_lacks() { ! audit_has "$1"; }

# Line N of the audit log contains the fixed string.
audit_line_has() {
  local line
  line="$(sed -n "$1p" "${CASE_HOME}/Library/Logs/launchd-run.log")"
  case "${line}" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Nothing but the audit log sits in ~/Library/Logs (no temp file left over).
logs_dir_has_only_audit() {
  local n
  n="$(find "${CASE_HOME}/Library/Logs" -mindepth 1 | wc -l | tr -d ' ')"
  [ "${n}" -eq 1 ]
}

# Writes N audit-shaped lines (about 60 bytes each) as the case's log.
seed_audit_lines() {
  awk -v n="$1" 'BEGIN {
    for (i = 1; i <= n; i++) {
      printf "2026-01-01 00:00:00  seed%-34s line %05d\n", "", i
    }
  }' >"${CASE_HOME}/Library/Logs/launchd-run.log"
}

audit_lines_are() {
  local f="${CASE_HOME}/Library/Logs/launchd-run.log" n=0
  [ -f "${f}" ] && n="$(wc -l <"${f}" | tr -d ' ')"
  [ "${n}" -eq "$1" ]
}

err_has() { grep -F -q -- "$1" "${CASE_DIR}/err"; }
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
  local marker value
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
  check '--after with no value: exit 64' rc_is 64
  check '--after with no value: usage error on stderr' err_has 'usage'

  for value in abc 0 -1 1x ''; do
    new_case
    marker="${CASE_DIR}/ran"
    run_wrap job --after "${value}" -- /usr/bin/touch "${marker}"
    check "--after '${value}': rejected with exit 64" rc_is 64
    check "--after '${value}': usage error on stderr" err_has 'usage'
    check "--after '${value}': command not run" path_absent "${marker}"
    check "--after '${value}': no state written" state_dir_absent
  done

  new_case
  seed_counter job 0
  run_wrap job --after 0 -- /usr/bin/true
  check '--after 0: no recovery banner, command not run' calls_are 0
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
  check 'ok: start line first, naming the wrapper version' \
    audit_line_has 1 "started: launchd-run ${TEST_VERSION}"
  check 'ok: start line carries the label' audit_line_has 1 ' job '
  check 'ok: outcome line second' audit_line_has 2 'ok ('
  check 'ok: exactly two audit lines' audit_lines_are 2
  check 'ok: version not on the job stdout' out_is 'a b|c'
  check 'ok: version not on the job stderr' \
    [ "$(cat "${CASE_DIR}/err")" = 'to-err' ]
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
  check 'fail 2: banner text, title and subtitle passed as argv' \
    call_has 1 \
    '| exit 3 on 2 consecutive runs - see the log | launchd: job | Job failing'
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

  echo '# banner text is argv, so quotes in the label reach osascript intact'
  new_case
  seed_counter 'say "hi"' 1
  run_wrap 'say "hi"' -- /bin/sh -c 'exit 3'
  check 'quoted label: banner raised' calls_are 1
  check 'quoted label: label reaches osascript verbatim' \
    call_has 1 '| launchd: say "hi" | Job failing'
  check 'quoted label: AppleScript takes its text from argv' \
    call_has 1 'display notification msg with title ttl subtitle sub |'
  check 'quoted label: audit records alert sent' \
    audit_has 'alert sent: Job failing'

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
  check 'recovery: text, title and subtitle passed as argv' \
    call_has 1 \
    '| succeeded after 2 failed runs | launchd: job | Back to normal'
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
  check 'cycle: three start lines, three outcomes, two alert lines' \
    audit_lines_are 8
}

test_stop_signals() {
  local sig
  # Issues #21 #22: only a signal to the wrapper makes a stop. The same codes
  # with the wrapper never signalled are failures.
  echo '# exit 129/130/137/143 with no signal to the wrapper: counted'
  for sig in 129 130 137 143; do
    new_case
    seed_counter job 1
    run_wrap job -- /bin/sh -c "exit ${sig}"
    check "exit ${sig}: passed through" rc_is "${sig}"
    check "exit ${sig}: counted, streak 1 -> 2" counter_is job 2
    check "exit ${sig}: banner at threshold" calls_are 1
    check "exit ${sig}: audit FAILED line" audit_has "FAILED exit ${sig} ("

    new_case
    run_wrap job -- /bin/sh -c "exit ${sig}"
    check "exit ${sig} with no streak: counter starts at 1" counter_is job 1
  done

  # A real stop at the threshold: the wrapper is signalled and the job exits
  # 1, a code the old exit-code rule would have counted.
  new_case
  seed_counter svc 2
  if ! stop_wrapper_with TERM \
    "trap 'kill \$!; exit 1' TERM; /bin/sleep 30 & wait \$!"; then
    check 'stop at threshold: wrapper started the job' false
  else
    check 'stop at threshold: streak of 2 preserved' counter_is svc 2
    check 'stop at threshold: no banner' calls_are 0
    run_wrap svc -- /usr/bin/true
    check 'stop then ok: recovery reports the preserved streak' \
      call_has 1 'succeeded after 2 failed runs'
  fi

  new_case
  seed_counter job 1
  run_wrap job -- /bin/sh -c 'kill -TERM $$'
  check 'child really killed by SIGTERM: exit 143' rc_is 143
  check 'child really killed by SIGTERM: counted, streak 1 -> 2' \
    counter_is job 2
  check 'child really killed by SIGTERM: audit FAILED line' \
    audit_has 'FAILED exit 143 ('
}

test_crash_signals() {
  local sig
  echo '# crash signals 134/138/139 are failures'
  for sig in 134 138 139; do
    new_case
    seed_counter job 1
    # Through perl: the wrapper now dies of the signal (139 is SIGSEGV), and
    # run_wrap would have this shell print its own "Segmentation fault".
    run_wrap_raw job -- /bin/sh -c "exit ${sig}"
    check "exit ${sig}: passed through" rc_is "${sig}"
    check "exit ${sig}: wrapper killed by signal $((sig - 128))" \
      [ "${KILLED_BY}" = "$((sig - 128))" ]
    check "exit ${sig}: counter 1 -> 2" counter_is job 2
    check "exit ${sig}: banner at threshold" calls_are 1
    check "exit ${sig}: banner names the exit code" \
      call_has 1 "exit ${sig} on 2 consecutive runs"
    check "exit ${sig}: audit FAILED line" audit_has "FAILED exit ${sig} ("
  done

  # launchd's KeepAlive Crashed key restarts a job only if it died of a
  # crash signal, so the wrapper must die of it too, not exit 128+N.
  echo '# a real crash: the wrapper dies of the same signal'
  for sig in SEGV ABRT; do
    new_case
    seed_counter job 1
    run_wrap_raw job -- /bin/sh -c "ulimit -c 0; kill -${sig} \$\$"
    check "SIG${sig}: wrapper killed by SIG${sig}" \
      [ "${KILLED_BY}" = "$(kill -l "${sig}")" ]
    check "SIG${sig}: counter 1 -> 2" counter_is job 2
    check "SIG${sig}: banner at threshold" calls_are 1
    check "SIG${sig}: audit FAILED line" \
      audit_has "FAILED exit $((128 + $(kill -l "${sig}"))) ("
    check "SIG${sig}: no shell crash report on the job's stderr" err_empty
  done

  new_case
  run_wrap_raw job -- /bin/sh -c 'exit 3'
  check 'plain failure: wrapper exits normally' [ "${KILLED_BY}" = 0 ]
  check 'plain failure: exit 3' rc_is 3
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
  check 'empty counter, ok: no error noise' err_empty

  new_case
  seed_counter job ''
  run_wrap job -- /bin/sh -c 'exit 3'
  check 'empty counter, fail: exit 3' rc_is 3
  check 'empty counter, fail: counter restarts at 1' counter_is job 1
  check 'empty counter, fail: no banner' calls_are 0
  check 'empty counter, fail: no error noise' err_empty

  # A word would read as an unset variable in $(( )), a bad number would fail
  # the expansion, and 08 would be rejected as octal; all must read as 0.
  echo '# garbage counter file'
  for content in garbage 12abc 08 -1; do
    new_case
    seed_counter job "${content}"
    run_wrap job -- /usr/bin/true
    check "counter '${content}', ok: exit 0" rc_is 0
    check "counter '${content}', ok: counter removed" counter_absent job
    check "counter '${content}', ok: no banner" calls_are 0
    check "counter '${content}', ok: no error on the job's stderr" err_empty

    new_case
    seed_counter job "${content}"
    run_wrap job -- /bin/sh -c 'exit 3'
    check "counter '${content}', fail: job exit 3 passed through" rc_is 3
    check "counter '${content}', fail: counter reset to 1" counter_is job 1
    check "counter '${content}', fail: FAILED audit line written" \
      audit_has 'FAILED exit 3'
    check "counter '${content}', fail: no error noise" err_empty
  done

  # ~/.local/state as a file stands in for one left root-owned by a sudo
  # install: the counter cannot be written, so the streak would stick at 1
  # and never reach --after.
  echo '# state directory cannot be made'
  new_case
  mkdir -p "${CASE_HOME}/.local"
  : >"${CASE_HOME}/.local/state"
  run_wrap job -- /bin/sh -c 'exit 3'
  check 'unwritable state, fail: job exit 3 passed through' rc_is 3
  check 'unwritable state, fail: alerts on the first failure' calls_are 1
  check 'unwritable state, fail: banner says the count is lost' \
    call_has 1 'exit 3; its failure count cannot be saved - see the log'
  check 'unwritable state, fail: audit names the counter it cannot write' \
    audit_has 's, consecutive: unknown - cannot write'
  check 'unwritable state, fail: no error on the job stderr' err_empty
  run_wrap job -- /bin/sh -c 'exit 3'
  check 'unwritable state, fail again: alerts again' calls_are 2
  run_wrap job -- /usr/bin/true
  check 'unwritable state, ok: exit 0' rc_is 0
  check 'unwritable state, ok: no banner' calls_are 2
  check 'unwritable state, ok: no error on the job stderr' err_empty

  # A streak left in a directory the wrapper cannot write to (root-owned
  # after a sudo run) cannot be cleared, so a success must not claim a
  # recovery that the next run would claim again.
  echo '# fail count that cannot be cleared'
  new_case
  seed_counter job 2
  chmod a-w "${CASE_HOME}/.local/state/launchd-run/job"
  if : 2>/dev/null >"${CASE_HOME}/.local/state/launchd-run/job/probe"; then
    # Root, or a filesystem (Windows) that ignores directory permissions.
    printf 'skip        %s\n' 'uncleared count: directory is still writable'
  else
    run_wrap job -- /usr/bin/true
    check 'uncleared count, ok: exit 0' rc_is 0
    check 'uncleared count, ok: no recovery banner' calls_are 0
    check 'uncleared count, ok: audit names the counter it cannot clear' \
      audit_has 's) - cannot clear'
    check 'uncleared count, ok: no error on the job stderr' err_empty
  fi
  chmod u+w "${CASE_HOME}/.local/state/launchd-run/job"
}

#######################################
# Starts the wrapper in the background around a job that records its own
# pid, then sends the wrapper the given signal once the job is up. This is
# what launchctl kill, bootout, logout and a KeepAlive restart do: the
# signal lands on the wrapper, not on the job.
# Globals:
#   RC (set to the wrapper's exit status)
#   CHILD (set to the job's pid, or empty if the job never started)
# Arguments:
#   Signal name, then the body of the job script (sh; $1 is the pid file).
#######################################
stop_wrapper_with() {
  local sig="$1" body="$2" job pidfile wpid
  job="${CASE_DIR}/job.sh"
  pidfile="${CASE_DIR}/child.pid"
  # shellcheck disable=SC2016  # Expanded by the job script, not here.
  printf '#!/bin/sh\necho $$ >"$1"\n%s\n' "${body}" >"${job}"
  chmod +x "${job}"

  # env execs the wrapper, so $! is the wrapper's own bash. SIGINT is not
  # tested: a non-interactive shell starts async jobs with SIGINT ignored,
  # so the wrapper could neither receive nor trap it from here.
  env HOME="${CASE_HOME}" PATH="${STUB_BIN}:${SYS_PATH}" \
    OSASCRIPT_CALLS="${CASE_DIR}/osascript.calls" \
    REPO_VERSION="${TEST_VERSION}" \
    "${WRAPPER}" svc -- "${job}" "${pidfile}" \
    >"${CASE_DIR}/out" 2>"${CASE_DIR}/err" &
  wpid=$!

  CHILD=''
  if ! wait_for_file "${pidfile}"; then
    kill -KILL "${wpid}" 2>/dev/null
    wait "${wpid}" 2>/dev/null
    return 1
  fi
  CHILD="$(cat "${pidfile}")"
  leftover_pids="${leftover_pids} ${CHILD}"
  # The job is up; give the wrapper a moment to reach its wait.
  sleep 0.2

  kill "-${sig}" "${wpid}"
  # The braces keep bash's "Terminated" job report out of the test output.
  { wait "${wpid}"; } 2>/dev/null
  RC=$?
}

test_signal_to_wrapper() {
  local sig
  echo '# stop signal sent to the wrapper itself (launchctl kill, bootout)'
  for sig in TERM HUP; do
    new_case
    seed_counter svc 1
    if ! stop_wrapper_with "${sig}" 'exec /bin/sleep 30'; then
      check "SIG${sig} to wrapper: wrapper started the job" false
      continue
    fi
    check "SIG${sig} to wrapper: exits 143" rc_is 143
    check "SIG${sig} to wrapper: streak of 1 untouched" counter_is svc 1
    check "SIG${sig} to wrapper: no banner" calls_are 0
    check "SIG${sig} to wrapper: stop recorded in the audit log" \
      audit_has 'stopped by signal (exit 143'
    check "SIG${sig} to wrapper: forwarded, job not orphaned" \
      pid_gone "${CHILD}"
    check "SIG${sig} to wrapper: no job-control noise on stderr" err_empty
  done

  echo '# job handles SIGTERM itself and exits 0: a stop, streak kept'
  new_case
  seed_counter svc 1
  # sleep runs in the background so sh can act on the trap at once, and the
  # trap takes it down so the suite leaves nothing behind.
  if ! stop_wrapper_with TERM \
    "trap 'kill \$!; exit 0' TERM; /bin/sleep 30 & wait \$!"; then
    check 'clean stop: wrapper started the job' false
    return
  fi
  check 'clean stop: job exit 0 passed through' rc_is 0
  check 'clean stop: logged as a stop' audit_has 'stopped by signal (exit 0,'
  check 'clean stop: streak kept' counter_is svc 1
  check 'clean stop: no banner' calls_are 0
  check 'clean stop: job gone' pid_gone "${CHILD}"
}

# Issue #21: a stop is known from the wrapper being signalled, not from the
# job's exit code. A job that handles SIGTERM with any exit code was stopped,
# so the run must neither count nor clear a streak.
test_stop_classified_by_wrapper() {
  local body
  echo '# #21: wrapper signalled, job exits 1 on SIGTERM: a stop, not counted'
  new_case
  seed_counter svc 1
  body="trap 'kill \$!; exit 1' TERM; /bin/sleep 30 & wait \$!"
  if ! stop_wrapper_with TERM "${body}"; then
    check '#21 exit 1 on stop: wrapper started the job' false
  else
    check '#21 exit 1 on stop: job exit 1 passed through' rc_is 1
    check '#21 exit 1 on stop: streak of 1 untouched' counter_is svc 1
    check '#21 exit 1 on stop: no banner' calls_are 0
    check '#21 exit 1 on stop: not logged as a failure' audit_lacks 'FAILED'
    check '#21 exit 1 on stop: job gone' pid_gone "${CHILD}"
  fi
  # Two routine restarts must not reach the default --after 2.
  /bin/rm -f "${CASE_DIR}/child.pid"
  if stop_wrapper_with TERM "${body}"; then
    check '#21 second stop: streak of 1 still untouched' counter_is svc 1
    check '#21 second stop: still no "Job failing" banner' calls_are 0
  else
    check '#21 second stop: wrapper started the job' false
  fi

  echo '# #21: wrapper signalled, job exits 0 on SIGTERM: streak kept'
  new_case
  seed_counter svc 5
  body="trap 'kill \$!; exit 0' TERM; /bin/sleep 30 & wait \$!"
  if ! stop_wrapper_with TERM "${body}"; then
    check '#21 exit 0 on stop: wrapper started the job' false
    return
  fi
  check '#21 exit 0 on stop: job exit 0 passed through' rc_is 0
  check '#21 exit 0 on stop: streak of 5 kept' counter_is svc 5
  check '#21 exit 0 on stop: no "Back to normal" banner' calls_are 0
  check '#21 exit 0 on stop: no recovery logged' audit_lacks 'Back to normal'
  check '#21 exit 0 on stop: job gone' pid_gone "${CHILD}"
}

# Issue #22: with the wrapper in front, launchd's stops signal the wrapper.
# A job that dies of SIGKILL or SIGTERM while the wrapper was not signalled
# (jetsam, its own timeout -s KILL, a manual kill) failed, and counts.
test_unexplained_signal_deaths() {
  local sig code
  echo '# #22: job killed by a signal the wrapper never got: counted'
  for sig in KILL TERM; do
    code=$((128 + $(kill -l "${sig}")))
    new_case
    seed_counter job 1
    run_wrap job -- /bin/sh -c "kill -${sig} \$\$"
    check "#22 SIG${sig} unexplained: exit ${code} passed through" \
      rc_is "${code}"
    check "#22 SIG${sig} unexplained: counter 1 -> 2" counter_is job 2
    check "#22 SIG${sig} unexplained: banner at threshold" calls_are 1
    check "#22 SIG${sig} unexplained: banner names exit ${code}" \
      call_has 1 "exit ${code} on 2 consecutive runs"
    check "#22 SIG${sig} unexplained: not logged as not counted" \
      audit_lacks 'not counted'

    new_case
    run_wrap job -- /bin/sh -c "kill -${sig} \$\$"
    check "#22 SIG${sig} unexplained, no streak: counter starts at 1" \
      counter_is job 1
  done
}

#######################################
# Stands in for launchd stopping a job (bootout, launchctl kill): starts the
# wrapper in the background around a job, sends the wrapper SIGTERM once the
# job is up and, as launchd does after ExitTimeOut, SIGKILL if the wrapper is
# still there EXIT_TIMEOUT seconds later. Unlike stop_wrapper_with, the job
# script writes its own pid file, so it can set its traps first.
# Globals:
#   RC (set to the wrapper's exit status)
#   CHILD (set to the job's pid, or empty if the job never started)
#   WRAPPER_KILLED (set to 1 if the stand-in had to SIGKILL the wrapper)
#   STOP_SECONDS (set to the whole seconds from SIGTERM to the wrapper's end)
#   STOP_MS (set to the same span in milliseconds, never understated)
#   WRAPPER_SECONDS (read: if not empty, the wrapper inherits it as SECONDS)
# Arguments:
#   The stand-in's ExitTimeOut in seconds, the body of the job script (sh; it
#   must write its pid to $1 once it is ready), then any wrapper options.
#######################################
launchd_stop() {
  local exit_timeout="$1" body="$2" job pidfile wpid t0
  local t0_ms
  shift 2
  job="${CASE_DIR}/job.sh"
  pidfile="${CASE_DIR}/child.pid"
  printf '#!/bin/sh\n%s\n' "${body}" >"${job}"
  chmod +x "${job}"

  env HOME="${CASE_HOME}" PATH="${STUB_BIN}:${SYS_PATH}" \
    OSASCRIPT_CALLS="${CASE_DIR}/osascript.calls" \
    REPO_VERSION="${TEST_VERSION}" \
    ${WRAPPER_SECONDS:+"SECONDS=${WRAPPER_SECONDS}"} \
    "${WRAPPER}" svc "$@" -- "${job}" "${pidfile}" \
    >"${CASE_DIR}/out" 2>"${CASE_DIR}/err" &
  wpid=$!

  CHILD=''
  WRAPPER_KILLED=0
  STOP_SECONDS=0
  if ! wait_for_file "${pidfile}"; then
    kill -KILL "${wpid}" 2>/dev/null
    wait "${wpid}" 2>/dev/null
    return 1
  fi
  CHILD="$(cat "${pidfile}")"
  leftover_pids="${leftover_pids} ${CHILD}"
  # The job is ready; give the wrapper time to set its trap and reach its
  # wait. A stop that lands before then is issue #27, not what is tested here.
  sleep 1

  # Read before the SIGTERM is sent, so STOP_MS can only overstate how long
  # the wrapper took: a lower bound checked against it never fails falsely.
  t0_ms="$(now_ms)"
  t0="${SECONDS}"
  kill -TERM "${wpid}"
  # The braces keep bash's "Killed" report of the wrapper out of the output.
  {
    while kill -0 "${wpid}"; do
      if ((SECONDS - t0 >= exit_timeout)); then
        kill -KILL "${wpid}"
        WRAPPER_KILLED=1
        break
      fi
      sleep 0.1
    done
    wait "${wpid}"
    RC=$?
  } 2>/dev/null
  STOP_SECONDS=$((SECONDS - t0))
  STOP_MS=$(($(now_ms) - t0_ms))
}

# The clock in milliseconds (bash 3.2 has no EPOCHREALTIME, BSD date no %N).
now_ms() {
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
}

stop_took_ms_at_least() { [ "${STOP_MS}" -ge "$1" ]; }
stop_took_ms_at_most() { [ "${STOP_MS}" -le "$1" ]; }
wrapper_killed() { [ "${WRAPPER_KILLED}" -eq 1 ]; }
wrapper_not_killed() { [ "${WRAPPER_KILLED}" -eq 0 ]; }
stop_took_at_least() { [ "${STOP_SECONDS}" -ge "$1" ]; }
pid_alive() { kill -0 "$1" 2>/dev/null; }

# Polls for up to ~3 s until no process is left sleeping for exactly $1
# seconds. Any that remain are queued for cleanup.
no_sleep_left() {
  local i=0 strays
  strays="$(pgrep -f "sleep $1\$")"
  while [ -n "${strays}" ] && [ "${i}" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
    strays="$(pgrep -f "sleep $1\$")"
  done
  leftover_pids="${leftover_pids} ${strays}"
  [ -z "${strays}" ]
}

# Issue #24: --kill-after is validated the way --after is, and neither
# option disturbs the other or an ordinary run.
test_kill_after_arguments() {
  local marker value
  echo '# #24: --kill-after arguments'

  new_case
  run_wrap
  check 'no arguments: usage names --kill-after' err_has '[--kill-after '

  new_case
  run_wrap job --kill-after
  check '--kill-after with no value: exit 64' rc_is 64
  check '--kill-after with no value: says what it needs' \
    err_has '--kill-after needs a positive integer'

  new_case
  run_wrap job --kill-after 3
  check '--kill-after N with no command: exit 64' rc_is 64
  check '--kill-after N with no command: "no command given"' \
    err_has 'no command given'

  for value in abc 0 -1 1x 1.5 ''; do
    new_case
    marker="${CASE_DIR}/ran"
    run_wrap job --kill-after "${value}" -- /usr/bin/touch "${marker}"
    check "--kill-after '${value}': rejected with exit 64" rc_is 64
    check "--kill-after '${value}': says what it needs" \
      err_has "--kill-after needs a positive integer, got '${value}'"
    check "--kill-after '${value}': command not run" path_absent "${marker}"
    check "--kill-after '${value}': no state written" state_dir_absent
  done

  # More than 9 digits is refused. A deadline that large is never reached,
  # and one big enough to wrap bash's arithmetic round to the past would
  # kill the job the moment it is stopped.
  for value in 1000000000 99999999999999999999; do
    new_case
    marker="${CASE_DIR}/ran"
    run_wrap job --kill-after "${value}" -- /usr/bin/touch "${marker}"
    check "--kill-after ${value}: rejected with exit 64" rc_is 64
    check "--kill-after ${value}: says the limit" \
      err_has "--kill-after takes at most 9 digits, got '${value}'"
    check "--kill-after ${value}: command not run" path_absent "${marker}"
    check "--kill-after ${value}: no state written" state_dir_absent
  done

  new_case
  run_wrap job --kill-after 999999999 -- /usr/bin/true
  check '--kill-after 999999999, the most allowed: exit 0' rc_is 0

  new_case
  marker="${CASE_DIR}/ran"
  run_wrap job --kill-after 5 -- /usr/bin/touch "${marker}"
  check '--kill-after 5, job ends by itself: exit 0' rc_is 0
  check '--kill-after 5, job ends by itself: command ran' test -e "${marker}"
  check '--kill-after 5, job ends by itself: logged ok' audit_has 'ok ('
  check '--kill-after 5, job ends by itself: nothing on stderr' err_empty

  new_case
  run_wrap job --after 1 --kill-after 5 -- /usr/bin/false
  check '--after 1 --kill-after 5: exit 1 passed through' rc_is 1
  check '--after 1 --kill-after 5: banner at the --after threshold' \
    calls_are 1

  new_case
  run_wrap job --kill-after 5 --after 1 -- /usr/bin/false
  check '--kill-after 5 --after 1: exit 1 passed through' rc_is 1
  check '--kill-after 5 --after 1: banner at the --after threshold' \
    calls_are 1
}

# Issue #24: launchd SIGKILLs the wrapper, and only the wrapper, once
# ExitTimeOut has passed, so a job that ignores SIGTERM outlives it as an
# orphan with no outcome line. With --kill-after N the wrapper SIGKILLs the
# job itself N seconds after forwarding SIGTERM, reaps it and logs the stop,
# all before launchd's SIGKILL is due.
test_kill_deadline() {
  local body timer_secs
  echo '# #24: job ignores SIGTERM, --kill-after 2: killed, reaped, logged'
  new_case
  seed_counter svc 1
  # One process, so nothing here depends on grandchildren (issue #44).
  body="trap '' TERM; echo \$\$ >\"\$1\"; exec /bin/sleep 120"
  if ! launchd_stop 20 "${body}" --kill-after 2; then
    check '#24 deadline: wrapper started the job' false
  else
    check '#24 deadline: wrapper finished before the launcher SIGKILL' \
      wrapper_not_killed
    check '#24 deadline: job gone, not orphaned' pid_gone "${CHILD}"
    check '#24 deadline: job had its 2 s first' stop_took_at_least 2
    check '#24 deadline: and not a moment less than 2 s' \
      stop_took_ms_at_least 2000
    # Due inside 3 s by the clock; the rest is room for a loaded machine.
    check '#24 deadline: and no more than 10 s' stop_took_ms_at_most 10000
    check '#24 deadline: exit 137 passed through' rc_is 137
    check '#24 deadline: outcome line names the SIGKILL' \
      audit_has 'stopped by signal, SIGKILL after 2s (exit 137, '
    check '#24 deadline: outcome line says not counted' \
      audit_has 's) - not counted'
    check '#24 deadline: not logged as a failure' audit_lacks 'FAILED'
    check '#24 deadline: streak of 1 untouched' counter_is svc 1
    check '#24 deadline: no banner' calls_are 0
    check '#24 deadline: no job-control noise on stderr' err_empty
  fi

  echo '# #24: a SECONDS the wrapper inherits cannot bring the deadline forward'
  new_case
  body="trap '' TERM; echo \$\$ >\"\$1\"; exec /bin/sleep 120"
  # Six below the top of bash's arithmetic. Once the wrapper has run for a
  # second, a 5 s deadline and its extra tick added to that wrap round to
  # the past, and the job would be killed the moment it is stopped. (After
  # seven seconds SECONDS itself has wrapped and the case shows nothing.)
  WRAPPER_SECONDS=9223372036854775801
  if ! launchd_stop 20 "${body}" --kill-after 5; then
    check '#24 inherited SECONDS: wrapper started the job' false
  else
    check '#24 inherited SECONDS: job still had its 5 s' \
      stop_took_ms_at_least 5000
    check '#24 inherited SECONDS: killed at the deadline all the same' \
      audit_has 'stopped by signal, SIGKILL after 5s (exit 137, '
    check '#24 inherited SECONDS: wrapper done before the launcher SIGKILL' \
      wrapper_not_killed
    check '#24 inherited SECONDS: job gone' pid_gone "${CHILD}"
  fi
  WRAPPER_SECONDS=''

  echo '# #24: job shuts down within the deadline: not killed, no waiting'
  new_case
  seed_counter svc 1
  # A deadline no other run of this suite uses, and far past the stand-in's
  # 20 s: a wrapper that waited it out, or left its timer behind, is caught.
  timer_secs=$((100000 + $$))
  body="trap 'kill \$!; /bin/sleep 1; exit 3' TERM; /bin/sleep 120 &
echo \$\$ >\"\$1\"; wait \$!"
  if ! launchd_stop 20 "${body}" --kill-after "${timer_secs}"; then
    check '#24 in time: wrapper started the job' false
  else
    check '#24 in time: wrapper did not wait out the deadline' \
      wrapper_not_killed
    check '#24 in time: job exit 3 passed through, not 137' rc_is 3
    check '#24 in time: logged as an ordinary stop' \
      audit_has 'stopped by signal (exit 3, '
    check '#24 in time: no SIGKILL logged' audit_lacks 'SIGKILL'
    check '#24 in time: streak of 1 untouched' counter_is svc 1
    check '#24 in time: no banner' calls_are 0
    check '#24 in time: job gone' pid_gone "${CHILD}"
    check '#24 in time: no deadline timer left behind' \
      no_sleep_left "${timer_secs}"
    check '#24 in time: no job-control noise on stderr' err_empty
  fi

  echo '# #24: without --kill-after nothing changes: the wrapper keeps waiting'
  new_case
  body="trap '' TERM; echo \$\$ >\"\$1\"; exec /bin/sleep 120"
  if ! launchd_stop 3 "${body}"; then
    check '#24 no option: wrapper started the job' false
  else
    check '#24 no option: wrapper still waiting at the launcher SIGKILL' \
      wrapper_killed
    check '#24 no option: job left alone' pid_alive "${CHILD}"
    check '#24 no option: no outcome line' audit_lacks 'stopped by signal'
    kill -KILL "${CHILD}" 2>/dev/null
  fi
}

test_log_rotation() {
  echo '# audit log trimmed to its last 5000 lines once past 1 MB'
  new_case
  seed_audit_lines 20000 # about 1.2 MB
  run_wrap job -- /usr/bin/true
  check 'rotation: exit 0' rc_is 0
  check 'rotation: 5000 kept, plus the trim note and this run' \
    audit_lines_are 5003
  check 'rotation: the newest seed lines are the ones kept' \
    audit_line_has 1 'line 15001'
  check 'rotation: older lines gone' audit_lacks 'line 15000'
  check 'rotation: trim recorded in the log' \
    audit_line_has 5001 'audit log trimmed to the last 5000 lines'
  check 'rotation: this run starts after the trim' \
    audit_line_has 5002 "started: launchd-run ${TEST_VERSION}"
  check 'rotation: this run logged after the trim' audit_line_has 5003 'ok ('
  check 'rotation: no temp file left beside the log' logs_dir_has_only_audit

  echo '# a log under 1 MB is left alone'
  new_case
  seed_audit_lines 100
  run_wrap job -- /usr/bin/true
  check 'no rotation: all lines kept plus this run' audit_lines_are 102
  check 'no rotation: first line intact' audit_line_has 1 'line 00001'
  check 'no rotation: nothing about a trim' audit_lacks 'trimmed'
}

# --- lr-stop: issues #27, #37, #25 and #41. ---------------------------------
# A check described "lr-stop:" fails on the wrapper these issues were filed
# against; one described "lr-stop-guard:" passes on it and must keep passing.

# Read by lr_stop_start: a directory to put first on PATH, and the command
# (and, if not empty, the first argument) that the gate stub there holds.
LR_PATH_PREFIX=''
LR_GATE_CMD=''
LR_GATE_ARG=''
# Set by lr_stop_start.
LR_WPID=''
LR_LAUNCHER=''

# Polls until a file exists and is not empty, for up to ~20 s.
lr_stop_wait_for() {
  local i=0
  while [ ! -s "$1" ] && [ "${i}" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$1" ]
}

# Lines in a file, 0 if it is missing.
lr_stop_lines() {
  if [ -f "$1" ]; then
    wc -l <"$1" | tr -d ' '
  else
    echo 0
  fi
}

# Polls until a file holds at least N lines, for up to ~20 s.
lr_stop_wait_lines() {
  local i=0
  while [ "$(lr_stop_lines "$1")" -lt "$2" ] && [ "${i}" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(lr_stop_lines "$1")" -ge "$2" ]
}

lr_stop_lines_are() { [ "$(lr_stop_lines "$1")" -eq "$2" ]; }
lr_stop_file_is() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }
lr_stop_not_killed() { [ "${KILLED_BY}" = 0 ]; }
# The wrapper exited with this status rather than being killed by a signal.
lr_stop_exited_with() { [ "${KILLED_BY}" = 0 ] && rc_is "$1"; }
lr_stop_source_lacks() { ! grep -F -q -- "$1" "${WRAPPER}"; }
lr_stop_readme_has() { grep -F -q -- "$1" "${REPO}/README.md"; }

#######################################
# Writes the case's job script (sh). It is run with one argument, the pid
# file $CASE_DIR/child.pid, and writes its pid there once its traps are set.
# Arguments:
#   The body of the script.
#######################################
lr_stop_job() {
  printf '#!/bin/sh\n%s\n' "$1" >"${CASE_DIR}/job.sh"
  chmod +x "${CASE_DIR}/job.sh"
}

#######################################
# Puts a gate in front of a command the wrapper runs before it forks the job.
# The first call of it (with the given first argument, if one is given)
# writes $CASE_DIR/ready and holds until $CASE_DIR/go exists (~20 s at most),
# then runs the real command, so a signal sent while it holds reaches the
# wrapper at a known point.
# Globals:
#   LR_PATH_PREFIX, LR_GATE_CMD, LR_GATE_ARG (set)
# Arguments:
#   The command (one that lives in /bin), then its first argument or ''.
#######################################
lr_stop_gate() {
  local dir="${CASE_DIR}/gate"
  mkdir -p "${dir}"
  # shellcheck disable=SC2016  # Expanded by the gate, not here.
  printf '%s\n' '#!/bin/bash' \
    'n="${0##*/}" g="${LR_G_DIR}"' \
    'if [ "${n}" = "${LR_G_CMD}" ] && [ ! -e "${g}/ready" ]; then' \
    '  if [ -n "${LR_G_ARG}" ] && [ "${1:-}" != "${LR_G_ARG}" ]; then' \
    '    exec "/bin/${n}" "$@"' \
    '  fi' \
    '  echo held >"${g}/ready"' \
    '  i=0' \
    '  while [ ! -e "${g}/go" ] && [ "${i}" -lt 200 ]; do' \
    '    /bin/sleep 0.1' \
    '    i=$((i + 1))' \
    '  done' \
    'fi' \
    'exec "/bin/${n}" "$@"' >"${dir}/$1"
  chmod +x "${dir}/$1"
  LR_PATH_PREFIX="${dir}"
  LR_GATE_CMD="$1"
  LR_GATE_ARG="$2"
}

#######################################
# Starts the wrapper in the background the way launchd does: with SIGINT and
# SIGQUIT at their defaults (a shell starts its background jobs with both
# ignored) and SIGPIPE too (a CI runner can start the suite with it ignored,
# which no shell can undo). It goes through a perl launcher that writes the
# wrapper's pid to $CASE_DIR/wrapper.pid and, once it ends, the signal that
# killed it (0 for none) to $CASE_DIR/killed-by.
# Globals:
#   LR_LAUNCHER (set to the launcher's pid)
#   LR_WPID (set to the wrapper's pid, or empty if it never started)
#   LR_PATH_PREFIX, LR_GATE_CMD, LR_GATE_ARG (read)
# Arguments:
#   Arguments for launchd-run.sh.
#######################################
lr_stop_start() {
  /bin/rm -f "${CASE_DIR}/wrapper.pid" "${CASE_DIR}/killed-by"
  # shellcheck disable=SC2016  # $SIG, $p, $s and the rest belong to perl.
  env HOME="${CASE_HOME}" \
    PATH="${LR_PATH_PREFIX:+${LR_PATH_PREFIX}:}${STUB_BIN}:${SYS_PATH}" \
    OSASCRIPT_CALLS="${CASE_DIR}/osascript.calls" \
    REPO_VERSION="${TEST_VERSION}" LR_G_DIR="${CASE_DIR}" \
    LR_G_CMD="${LR_GATE_CMD}" LR_G_ARG="${LR_GATE_ARG}" \
    /usr/bin/perl -e '$SIG{INT} = $SIG{QUIT} = $SIG{PIPE} = "DEFAULT";
      my ($pf, $kf) = splice(@ARGV, 0, 2);
      my $p = fork();
      defined($p) or die;
      if ($p == 0) { exec { $ARGV[0] } @ARGV; exit 127; }
      open(my $h, ">", "$pf.new") or die;
      print $h "$p\n";
      close($h);
      rename("$pf.new", $pf) or die;
      waitpid($p, 0);
      my $s = $?;
      open($h, ">", $kf) or die;
      print $h ($s & 127);
      close($h);
      exit(($s & 127) ? 128 + ($s & 127) : $s >> 8)' \
    "${CASE_DIR}/wrapper.pid" "${CASE_DIR}/killed-by" "${WRAPPER}" "$@" \
    >"${CASE_DIR}/out" 2>"${CASE_DIR}/err" &
  LR_LAUNCHER=$!
  LR_WPID=''
  if lr_stop_wait_for "${CASE_DIR}/wrapper.pid"; then
    LR_WPID="$(cat "${CASE_DIR}/wrapper.pid")"
  fi
}

#######################################
# Waits for the wrapper lr_stop_start began, SIGKILLing it if it is still
# there after the given number of seconds.
# Globals:
#   RC (set to the wrapper's exit status, or 128+N when killed by signal N)
#   KILLED_BY (set to the signal number that killed the wrapper, or 0)
# Arguments:
#   The limit in seconds.
#######################################
lr_stop_finish() {
  local limit="$1" t0="${SECONDS}"
  while kill -0 "${LR_LAUNCHER}" 2>/dev/null; do
    if ((SECONDS - t0 >= limit)); then
      if [ -n "${LR_WPID}" ]; then
        kill -KILL "${LR_WPID}" 2>/dev/null
      fi
      break
    fi
    sleep 0.1
  done
  wait "${LR_LAUNCHER}" 2>/dev/null
  RC=$?
  KILLED_BY="$(cat "${CASE_DIR}/killed-by" 2>/dev/null)"
}

# Kills the case's job if it is still running (the unfixed wrapper orphans
# it) and queues it for the suite's cleanup too.
lr_stop_reap() {
  local child
  child="$(cat "${CASE_DIR}/child.pid" 2>/dev/null)"
  if [ -n "${child}" ]; then
    kill -KILL "${child}" 2>/dev/null
    leftover_pids="${leftover_pids} ${child}"
  fi
}

# Starts the case's job under the wrapper and waits until it is up, then
# gives the wrapper a moment to reach its wait, as launchd_stop does.
lr_stop_start_job() {
  lr_stop_start svc "$@" -- "${CASE_DIR}/job.sh" "${CASE_DIR}/child.pid"
  lr_stop_wait_for "${CASE_DIR}/child.pid" || return 1
  sleep 1
}

# Issue #27: a stop that lands after the arguments are parsed but before the
# job is forked is not lost and does not kill the wrapper: the job is not
# started, the stop is logged and the streak is left alone.
test_lr_stop_27() {
  local spec cmd arg sig code marker what killed lost
  echo '# lr-stop #27: a stop before the job is forked'
  for spec in mkdir::TERM mkdir::HUP mkdir::INT date:+%s:TERM; do
    IFS=: read -r cmd arg sig <<<"${spec}"
    code=$((128 + $(kill -l "${sig}")))
    what="#27 SIG${sig} during ${cmd}${arg:+ ${arg}}"
    # Unfixed, TERM and HUP kill the wrapper. bash 3.2 outlives an INT that
    # lands while it waits for a command, so INT is lost instead: the job
    # runs as if nothing had happened.
    killed='lr-stop:'
    lost='lr-stop-guard:'
    if [ "${sig}" = INT ]; then
      killed='lr-stop-guard:'
      lost='lr-stop:'
    fi
    new_case
    seed_counter svc 1
    marker="${CASE_DIR}/ran"
    lr_stop_gate "${cmd}" "${arg}"
    lr_stop_start svc -- /usr/bin/touch "${marker}"
    if ! lr_stop_wait_for "${CASE_DIR}/ready"; then
      check "lr-stop-guard: ${what}: wrapper reached the gate" false
      : >"${CASE_DIR}/go"
      lr_stop_finish 20
    else
      kill "-${sig}" "${LR_WPID}"
      : >"${CASE_DIR}/go"
      lr_stop_finish 20
      check "${killed} ${what}: wrapper not killed by it" lr_stop_not_killed
      check "lr-stop: ${what}: exits ${code}" lr_stop_exited_with "${code}"
      check "lr-stop: ${what}: logged as a stop before the job started" \
        audit_has 'stopped by signal before the job started - not counted'
      check "${lost} ${what}: job not started" path_absent "${marker}"
      check "${lost} ${what}: streak of 1 untouched" counter_is svc 1
      check "lr-stop-guard: ${what}: no banner" calls_are 0
    fi
    LR_PATH_PREFIX=''
    LR_GATE_CMD=''
    LR_GATE_ARG=''
  done
}

# Issue #37: USR1, USR2 and ALRM are passed to the job as themselves and the
# wrapper keeps waiting; PIPE and QUIT are ignored by the wrapper. None of
# them ends the wrapper or loses the outcome line.
test_lr_stop_37() {
  local sig word
  echo '# lr-stop #37: USR1, USR2 and ALRM reach the job as themselves'
  for sig in USR1 USR2 ALRM; do
    new_case
    lr_stop_job "trap 'echo ${sig} >\"\$1.got\"; exit 3' ${sig}
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
    if ! lr_stop_start_job; then
      check "lr-stop-guard: #37 SIG${sig}: wrapper started the job" false
      lr_stop_finish 0
    else
      kill "-${sig}" "${LR_WPID}"
      lr_stop_finish 20
      check "lr-stop: #37 SIG${sig}: the job got SIG${sig}" \
        lr_stop_file_is "${CASE_DIR}/child.pid.got" "${sig}"
      check "lr-stop: #37 SIG${sig}: wrapper not killed by it" \
        lr_stop_not_killed
      check "lr-stop: #37 SIG${sig}: the job's exit 3 passed through" \
        lr_stop_exited_with 3
      check "lr-stop: #37 SIG${sig}: outcome logged" audit_has 'exit 3'
    fi
    lr_stop_reap
  done

  echo '# lr-stop #37: PIPE and QUIT do not end the wrapper'
  for sig in PIPE QUIT; do
    new_case
    lr_stop_job "echo \$\$ >\"\$1\"
while [ ! -e \"\$1.go\" ]; do /bin/sleep 0.1; done
exit 7"
    if ! lr_stop_start_job; then
      check "lr-stop-guard: #37 SIG${sig}: wrapper started the job" false
      lr_stop_finish 0
    else
      kill "-${sig}" "${LR_WPID}"
      : >"${CASE_DIR}/child.pid.go"
      lr_stop_finish 20
      check "lr-stop: #37 SIG${sig}: wrapper not killed by it" \
        lr_stop_not_killed
      check "lr-stop: #37 SIG${sig}: the job's exit 7 passed through" \
        lr_stop_exited_with 7
      check "lr-stop: #37 SIG${sig}: outcome logged" \
        audit_has 'FAILED exit 7 ('
    fi
    lr_stop_reap
  done

  echo '# lr-stop #37: a USR1 while a stopped job shuts down is passed on'
  new_case
  lr_stop_job "trap 'echo TERM >>\"\$1.terms\"' TERM
trap 'echo USR1 >\"\$1.got\"; exit 4' USR1
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
  if ! lr_stop_start_job; then
    check 'lr-stop-guard: #37 USR1 after a stop: wrapper started the job' false
    lr_stop_finish 0
  else
    kill -TERM "${LR_WPID}"
    if ! lr_stop_wait_lines "${CASE_DIR}/child.pid.terms" 1; then
      check 'lr-stop-guard: #37 USR1 after a stop: SIGTERM forwarded' false
    fi
    kill -USR1 "${LR_WPID}" 2>/dev/null
    lr_stop_finish 20
    check 'lr-stop: #37 USR1 after a stop: the job got SIGUSR1' \
      lr_stop_file_is "${CASE_DIR}/child.pid.got" USR1
    check "lr-stop: #37 USR1 after a stop: the job's exit 4 passed through" \
      lr_stop_exited_with 4
    check 'lr-stop: #37 USR1 after a stop: logged as a stop' \
      audit_has 'stopped by signal (exit 4,'
  fi
  lr_stop_reap

  # The wrapper may ignore PIPE, but the job must not inherit that: a job
  # that writes to a closed pipe dies of it, as it would without the wrapper.
  # Through the launcher, so that the wrapper itself starts with SIGPIPE at
  # its default whatever the suite inherited.
  new_case
  lr_stop_start job -- /bin/sh -c 'kill -PIPE $$; exit 0'
  lr_stop_finish 20
  check 'lr-stop-guard: #37 the job starts with SIGPIPE at its default' \
    rc_is 141

  for word in USR1 USR2 ALRM PIPE STOP; do
    check "lr-stop: #37 README says what SIG${word} does" \
      lr_stop_readme_has "${word}"
  done
}

# Issue #25: after a stop the wrapper waits for the job, however many more
# stops arrive (each forwarded as SIGTERM again), and logs and returns the
# job's own status, a death by signal included. --kill-after still ends the
# wait at its deadline.
test_lr_stop_25() {
  local child
  echo '# lr-stop #25: three stops while the job shuts down'
  new_case
  seed_counter svc 1
  lr_stop_job "n=0
log=\"\$HOME/Library/Logs/launchd-run.log\"
trap 'n=\$((n + 1)); echo TERM >>\"\$1.terms\"
if [ \"\$n\" -ge 3 ]; then
  grep -q \"stopped by signal\" \"\$log\" && echo early >\"\$1.early\"
  exit 5
fi' TERM
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
  if ! lr_stop_start_job; then
    check 'lr-stop-guard: #25 three stops: wrapper started the job' false
    lr_stop_finish 0
  else
    kill -TERM "${LR_WPID}"
    lr_stop_wait_lines "${CASE_DIR}/child.pid.terms" 1
    kill -HUP "${LR_WPID}" 2>/dev/null
    lr_stop_wait_lines "${CASE_DIR}/child.pid.terms" 2
    kill -INT "${LR_WPID}" 2>/dev/null
    lr_stop_finish 20
    check 'lr-stop: #25 three stops: each forwarded, three SIGTERMs' \
      lr_stop_lines_are "${CASE_DIR}/child.pid.terms" 3
    check "lr-stop: #25 three stops: the job's exit 5 passed through" \
      lr_stop_exited_with 5
    check "lr-stop: #25 three stops: logged with the job's exit 5" \
      audit_has 'stopped by signal (exit 5,'
    check 'lr-stop-guard: #25 three stops: no outcome before the job ended' \
      path_absent "${CASE_DIR}/child.pid.early"
    check 'lr-stop-guard: #25 three stops: streak of 1 untouched' \
      counter_is svc 1
    check 'lr-stop-guard: #25 three stops: no banner' calls_are 0
  fi
  lr_stop_reap

  echo '# lr-stop #25: the job dies of SIGKILL after a second stop'
  new_case
  lr_stop_job "trap 'echo TERM >>\"\$1.terms\"' TERM
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
  if ! lr_stop_start_job; then
    check 'lr-stop-guard: #25 death by signal: wrapper started the job' false
    lr_stop_finish 0
  else
    kill -TERM "${LR_WPID}"
    lr_stop_wait_lines "${CASE_DIR}/child.pid.terms" 1
    kill -TERM "${LR_WPID}" 2>/dev/null
    lr_stop_wait_lines "${CASE_DIR}/child.pid.terms" 2
    # No stop after this: one just after a death by signal is issue #52.
    child="$(cat "${CASE_DIR}/child.pid")"
    kill -KILL "${child}"
    lr_stop_finish 20
    check "lr-stop: #25 death by signal: the job's 137 passed through" \
      lr_stop_exited_with 137
    check "lr-stop: #25 death by signal: logged with the job's 137" \
      audit_has 'stopped by signal (exit 137,'
  fi
  lr_stop_reap

  echo '# lr-stop #25: with --kill-after a second stop keeps the deadline'
  new_case
  lr_stop_job "trap 'echo TERM >>\"\$1.terms\"' TERM
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
  if ! lr_stop_start_job --kill-after 2; then
    check 'lr-stop-guard: #25 --kill-after: wrapper started the job' false
    lr_stop_finish 0
  else
    kill -TERM "${LR_WPID}"
    lr_stop_wait_lines "${CASE_DIR}/child.pid.terms" 1
    kill -HUP "${LR_WPID}" 2>/dev/null
    lr_stop_finish 30
    check 'lr-stop-guard: #25 --kill-after: killed at the deadline, 137' \
      lr_stop_exited_with 137
    check 'lr-stop-guard: #25 --kill-after: the SIGKILL is logged' \
      audit_has 'stopped by signal, SIGKILL after 2s (exit 137, '
    check 'lr-stop-guard: #25 --kill-after: job gone' \
      pid_gone "$(cat "${CASE_DIR}/child.pid")"
  fi
  lr_stop_reap
}

# Issue #41: without set -e, the "|| true" after the label's shift is dead.
test_lr_stop_41() {
  echo '# lr-stop #41: the label shift'
  check 'lr-stop: #41 the dead "shift || true" is gone' \
    lr_stop_source_lacks 'shift || true'
}

# --- lr-env: the job's environment, HOME and command lookup. -----------------

# Every name the wrapper sets or declares (issue #23).
readonly LR_ENV_NAMES='REPO_ROOT LIB LABEL AUDIT EX_USAGE AUDIT_MAX_BYTES
  AUDIT_KEEP_LINES alert_after kill_after state started stopped pid code
  killed woke deadline_done fails prev fails_file elapsed sig'
# Of those, the locals of main first assigned after the job is forked: the
# job already gets the caller's value of these.
readonly LR_ENV_LATE=' code fails prev fails_file elapsed sig '
# Every function the wrapper defines (issue #30).
readonly LR_ENV_FUNCS='note notify main rotate_audit usage_error repo_version
  forward_signal kill_at_deadline'

# Read by lr_env_wrap: a directory put first on PATH, if not empty, and the
# REPO_VERSION to pin, none if empty.
LR_ENV_PATH=''
LR_ENV_VERSION="${TEST_VERSION}"
# Set by lr_env_dump_job.
LR_ENV_JOB=()

#######################################
# Runs the wrapper inside the current case, like run_wrap, with a chosen
# HOME and extra variables in its environment.
# Globals:
#   RC (set to the wrapper's exit status)
#   LR_ENV_PATH, LR_ENV_VERSION (read)
# Arguments:
#   HOME: "case" (the case's HOME), "unset" or "empty"; then NAME=value
#   pairs; then "::"; then arguments for launchd-run.sh.
#######################################
lr_env_wrap() {
  local home="$1"
  local cmd=(/usr/bin/env)
  shift
  case "${home}" in
    unset) cmd+=(-u HOME) ;;
    empty) cmd+=(HOME=) ;;
    *) cmd+=("HOME=${CASE_HOME}") ;;
  esac
  cmd+=("PATH=${LR_ENV_PATH:+${LR_ENV_PATH}:}${STUB_BIN}:${SYS_PATH}")
  cmd+=("OSASCRIPT_CALLS=${CASE_DIR}/osascript.calls")
  if [ -n "${LR_ENV_VERSION}" ]; then
    cmd+=("REPO_VERSION=${LR_ENV_VERSION}")
  fi
  while [ "$#" -gt 0 ] && [ "$1" != '::' ]; do
    cmd+=("$1")
    shift
  done
  shift
  "${cmd[@]}" "${WRAPPER}" "$@" >"${CASE_DIR}/out" 2>"${CASE_DIR}/err"
  RC=$?
}

#######################################
# Sets LR_ENV_JOB to the command line of a job that records, for each name
# given, whether it is in its environment and its value, in
# $CASE_DIR/env/<name> ("set:<value>" or "unset"), then exits with the given
# status.
# Globals:
#   LR_ENV_JOB (set)
# Arguments:
#   The exit status, then the names.
#######################################
lr_env_dump_job() {
  local status="$1"
  shift
  mkdir -p "${CASE_DIR}/env"
  # shellcheck disable=SC2016  # $d, $s and the rest belong to perl.
  LR_ENV_JOB=(/usr/bin/perl -e
    'my ($d, $s) = splice(@ARGV, 0, 2);
    for my $n (@ARGV) {
      open(my $h, ">", "$d/$n") or die;
      print $h (exists $ENV{$n} ? "set:$ENV{$n}" : "unset");
      close($h);
    }
    exit $s' "${CASE_DIR}/env" "${status}" "$@")
}

# The job saw this name with exactly this value ("unset" for none).
lr_env_job_saw() {
  local want="$2"
  [ -f "${CASE_DIR}/env/$1" ] || return 1
  [ "${want}" = unset ] || want="set:${want}"
  [ "$(
    cat "${CASE_DIR}/env/$1"
    echo x
  )" = "${want}x" ]
}

# Lines on the wrapper's stderr.
lr_env_err_lines_are() {
  [ "$(wc -l <"${CASE_DIR}/err" | tr -d ' ')" -eq "$1" ]
}

# The wrapper's stderr holds exactly one line, and it is not bash's own
# complaint about an unset variable.
lr_env_one_warning() {
  lr_env_err_lines_are 1 && ! err_has 'unbound variable'
}

# The file exists and the wrapper exited with this status.
lr_env_ran_with() { [ -e "$1" ] && rc_is "$2"; }

# Two start lines, the first not empty, are the same.
lr_env_same_start() { [ -n "$1" ] && [ "$1" = "$2" ]; }

lr_env_readme_has() { grep -F -q -- "$1" "${REPO}/README.md"; }

# The first audit line with its timestamp and label cut off.
lr_env_start_line() {
  sed -n '1s/^.*started: /started: /p' \
    "${CASE_HOME}/Library/Logs/launchd-run.log" 2>/dev/null
}

# Issue #23: a variable the caller set under a name the wrapper also uses
# reaches the job with the caller's value, and the wrapper itself still logs
# to its own audit file under its own label.
test_lr_env_23() {
  local name nasty unset_ok start_plain start_root tag
  echo '# lr-env #23: the caller'"'"'s variables reach the job intact'
  # shellcheck disable=SC2016  # Meant literally: it must never run.
  nasty=$'two words\n"dq" \'sq\' \\ * ; | & `x` $(touch pwned) $HOME'
  for name in ${LR_ENV_NAMES}; do
    new_case
    lr_env_dump_job 0 "${name}" LR_ENV_CONTROL
    (cd "${CASE_DIR}" \
      && lr_env_wrap case "${name}=${name}:${nasty}" LR_ENV_CONTROL=c :: \
        job -- "${LR_ENV_JOB[@]}")
    RC="$?"
    tag='lr-env:'
    case "${LR_ENV_LATE}" in
      *" ${name} "*) tag='lr-env-guard:' ;;
    esac
    check "${tag} #23 ${name}: reaches the job with the caller's value" \
      lr_env_job_saw "${name}" "${name}:${nasty}"
    check "lr-env-guard: #23 ${name}: control variable intact" \
      lr_env_job_saw LR_ENV_CONTROL c
    check "lr-env-guard: #23 ${name}: the job still exits 0" rc_is 0
    check "lr-env-guard: #23 ${name}: the value was never run" \
      path_absent "${CASE_DIR}/pwned"
  done

  for name in LABEL state AUDIT; do
    new_case
    lr_env_dump_job 0 "${name}"
    lr_env_wrap case "${name}=" :: job -- "${LR_ENV_JOB[@]}"
    check "lr-env: #23 ${name} set empty: reaches the job set and empty" \
      lr_env_job_saw "${name}" ''
  done

  echo '# lr-env #23: names the caller did not set stay unset'
  new_case
  # shellcheck disable=SC2086  # The list is split on purpose.
  lr_env_dump_job 0 ${LR_ENV_NAMES}
  lr_env_wrap case :: job -- "${LR_ENV_JOB[@]}"
  unset_ok=1
  for name in ${LR_ENV_NAMES}; do
    lr_env_job_saw "${name}" unset || unset_ok=''
  done
  check 'lr-env-guard: #23 no wrapper name appears in the job unasked' \
    [ -n "${unset_ok}" ]

  echo '# lr-env #23: the wrapper keeps its own label, log and streak'
  new_case
  seed_counter job 1
  lr_env_wrap case LABEL=other "AUDIT=${CASE_DIR}/other.log" \
    "state=${CASE_DIR}/other-state" "fails_file=${CASE_DIR}/other-count" \
    alert_after=99 kill_after=1 stopped=15 pid=notapid code=0 \
    EX_USAGE=7 AUDIT_MAX_BYTES=1 AUDIT_KEEP_LINES=1 \
    "LIB=${CASE_DIR}/nolib.sh" prev=50 fails=50 started=0 :: \
    job -- /bin/sh -c 'exit 3'
  check 'lr-env-guard: #23 all names set: the job'"'"'s exit 3 passed' rc_is 3
  check 'lr-env-guard: #23 all names set: logged under the real label' \
    audit_line_has 2 ' job '
  check 'lr-env-guard: #23 all names set: failure logged, streak 2' \
    audit_has 'FAILED exit 3 ('
  check 'lr-env-guard: #23 all names set: counter now 2' counter_is job 2
  check 'lr-env-guard: #23 all names set: banner at the default --after 2' \
    calls_are 1
  check 'lr-env-guard: #23 all names set: no log at the caller'"'"'s AUDIT' \
    path_absent "${CASE_DIR}/other.log"
  check 'lr-env-guard: #23 all names set: no state at the caller'"'"'s path' \
    path_absent "${CASE_DIR}/other-state"
  check 'lr-env-guard: #23 all names set: log not trimmed' \
    audit_lines_are 3

  new_case
  lr_env_wrap case EX_USAGE=7 :: job --bogus -- /usr/bin/true
  check 'lr-env-guard: #23 EX_USAGE set: a usage error still exits 64' \
    rc_is 64

  echo '# lr-env #23: a caller'"'"'s REPO_ROOT does not change the version'
  LR_ENV_VERSION=''
  new_case
  lr_env_wrap case :: job -- /usr/bin/true
  start_plain="$(lr_env_start_line)"
  new_case
  lr_env_wrap case "REPO_ROOT=${CASE_DIR}" :: job -- /usr/bin/true
  start_root="$(lr_env_start_line)"
  LR_ENV_VERSION="${TEST_VERSION}"
  check 'lr-env-guard: #23 REPO_ROOT set: start line names the checkout' \
    lr_env_same_start "${start_plain}" "${start_root}"
}

# Issue #26: with HOME unset or empty the wrapper runs the command directly
# with no bookkeeping and one warning line on stderr, and exits with the
# command's status. A malformed command line still exits 64 first.
test_lr_env_26() {
  local home marker tag quiet
  for home in unset empty; do
    echo "# lr-env #26: HOME ${home}"
    # With HOME empty the job already runs; its bookkeeping is the bug.
    tag='lr-env:'
    quiet='lr-env-guard:'
    if [ "${home}" = empty ]; then
      tag='lr-env-guard:'
      quiet='lr-env:'
    fi
    new_case
    marker="${CASE_DIR}/ran"
    # shellcheck disable=SC2016  # $1 belongs to the job's own sh.
    lr_env_wrap "${home}" :: job --after 1 -- \
      /bin/sh -c 'touch "$1"; echo job-out; exit 7' sh "${marker}"
    check "${tag} #26 HOME ${home}: the job ran" [ -e "${marker}" ]
    check "${tag} #26 HOME ${home}: exit status is the job's 7" rc_is 7
    check "${tag} #26 HOME ${home}: job stdout passed through" \
      out_is job-out
    check "lr-env: #26 HOME ${home}: one warning line on stderr" \
      lr_env_one_warning
    check "${quiet} #26 HOME ${home}: no banner, even at --after 1" \
      calls_are 0

    new_case
    marker="${CASE_DIR}/ran"
    lr_env_wrap "${home}" :: job -- /usr/bin/touch "${marker}"
    check "${tag} #26 HOME ${home}: a good job runs, exit 0" \
      lr_env_ran_with "${marker}" 0

    new_case
    marker="${CASE_DIR}/ran"
    lr_env_wrap "${home}" :: job --after 3 --kill-after 5 -- \
      /usr/bin/touch "${marker}"
    check "${tag} #26 HOME ${home}: options still parsed, the job runs" \
      [ -e "${marker}" ]

    new_case
    lr_env_dump_job 0 LABEL
    lr_env_wrap "${home}" LABEL=mine :: job -- "${LR_ENV_JOB[@]}"
    check "lr-env: #26 HOME ${home}: the caller's LABEL reaches the job" \
      lr_env_job_saw LABEL mine

    new_case
    marker="${CASE_DIR}/ran"
    lr_env_wrap "${home}" :: job --bogus -- /usr/bin/touch "${marker}"
    check "lr-env-guard: #26 HOME ${home}: unknown flag still exits 64" \
      rc_is 64
    check "lr-env-guard: #26 HOME ${home}: unknown flag: job not run" \
      path_absent "${marker}"
    new_case
    lr_env_wrap "${home}" :: job --after 0 -- /usr/bin/touch "${marker}"
    check "lr-env-guard: #26 HOME ${home}: --after 0 still exits 64" rc_is 64
    new_case
    lr_env_wrap "${home}" :: job
    check "lr-env-guard: #26 HOME ${home}: no command still exits 64" \
      rc_is 64
  done

  echo '# lr-env #26: README'
  check 'lr-env: #26 README covers a LaunchDaemon' \
    lr_env_readme_has LaunchDaemon
  check 'lr-env: #26 README names UserName' lr_env_readme_has UserName
}

#######################################
# Writes a program named like one of the wrapper's functions into the
# case's $CASE_DIR/path, which it puts first on PATH. It writes "ran" to the
# file given as its first argument and exits with the given status.
# Globals:
#   LR_ENV_PATH (set)
# Arguments:
#   The name, then the exit status.
#######################################
lr_env_path_program() {
  mkdir -p "${CASE_DIR}/path"
  # shellcheck disable=SC2016  # $1 belongs to the program.
  printf '#!/bin/sh\necho ran >"$1"\nexit %s\n' "$2" >"${CASE_DIR}/path/$1"
  chmod +x "${CASE_DIR}/path/$1"
  LR_ENV_PATH="${CASE_DIR}/path"
}

# Issue #30: a command named like one of the wrapper's functions runs the
# program on PATH, never the function.
test_lr_env_30() {
  local name code=10 marker
  echo '# lr-env #30: commands named like the wrapper'"'"'s functions'
  for name in ${LR_ENV_FUNCS}; do
    code=$((code + 1))
    new_case
    marker="${CASE_DIR}/ran"
    lr_env_path_program "${name}" "${code}"
    lr_env_wrap case :: job -- "${name}" "${marker}"
    check "lr-env: #30 ${name}: the program on PATH ran" [ -e "${marker}" ]
    check "lr-env: #30 ${name}: its exit ${code} passed through" \
      rc_is "${code}"
    check "lr-env: #30 ${name}: its exit ${code} logged" \
      audit_has "FAILED exit ${code} ("
    LR_ENV_PATH=''
  done

  for name in note main; do
    new_case
    marker="${CASE_DIR}/ran"
    lr_env_path_program "${name}" 0
    lr_env_wrap unset :: job -- "${name}" "${marker}"
    check "lr-env: #30 HOME unset: ${name} runs the program on PATH" \
      lr_env_ran_with "${marker}" 0
    LR_ENV_PATH=''
  done
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
  test_stop_classified_by_wrapper
  test_unexplained_signal_deaths
  test_kill_after_arguments
  test_kill_deadline
  test_log_rotation
  test_lr_stop_27
  test_lr_stop_37
  test_lr_stop_25
  test_lr_stop_41
  test_lr_env_23
  test_lr_env_26
  test_lr_env_30

  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
