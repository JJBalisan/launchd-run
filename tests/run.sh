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

  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
