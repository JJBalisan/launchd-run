#!/bin/bash
#
# Checks for the review findings on the lr-stop lane: a stop at the fork, a
# stop as the wrapper is about to wait, and the guard at the --kill-after
# SIGKILL. Each signal is injected at an exact point with a BASH_ENV DEBUG
# trap, so no check depends on timing. Loads the harness from run.sh without
# running its suite.
#
#   bash tests/lr_56_fix.sh     # also under /bin/bash 3.2

# The harness globals come from the eval, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
eval "$(/usr/bin/sed '/^main "\$@"$/d' "$(dirname "$0")/run.sh")"

#######################################
# Like lr_stop_start, with a directory list appended to PATH.
# Globals:
#   LR_LAUNCHER, LR_WPID (set)
# Arguments:
#   The PATH tail, then arguments for launchd-run.sh.
#######################################
lr56_start() {
  local tail="$1"
  shift
  /bin/rm -f "${CASE_DIR}/wrapper.pid" "${CASE_DIR}/killed-by"
  # shellcheck disable=SC2016  # $SIG, $p, $s and the rest belong to perl.
  env HOME="${CASE_HOME}" PATH="${STUB_BIN}:${SYS_PATH}:${tail}" \
    OSASCRIPT_CALLS="${CASE_DIR}/osascript.calls" \
    REPO_VERSION="${TEST_VERSION}" \
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
# Writes a BASH_ENV file that makes the wrapper's main shell (not a subshell
# of it) run one action at the Nth DEBUG event whose command matches a
# pattern, then writes $HOME/injected. A command follows the action inside
# the DEBUG trap, so a trap the action sets off runs there, before the
# wrapper's command.
# Arguments:
#   The file, the case pattern (no single quotes), N, then the action.
#######################################
lr56_env() {
  # shellcheck disable=SC2016  # Expanded by the wrapper's bash.
  printf '%s\n' 'set -T' '_lr56_n=0' \
    'trap '\''if [ "${BASH_SUBSHELL}" = 0 ]; then case "${BASH_COMMAND}" in '"$2"')
  _lr56_n=$((_lr56_n + 1))
  if [ "${_lr56_n}" = '"$3"' ]; then '"$4"'; echo x >>"${HOME}/injected"; fi ;;
esac; fi'\'' DEBUG' >"$1"
}

lr56_injected() { [ -s "${CASE_HOME}/injected" ]; }
lr56_job_gone() {
  local child
  child="$(cat "${CASE_DIR}/child.pid" 2>/dev/null)"
  [ -z "${child}" ] || ! pid_alive "${child}"
}

# F1: a stop forwarded to the job before it has exec'd. A 60,000-entry PATH
# keeps the forked process looking the command up; the wrapper SIGTERMs
# itself at the top of its first wait loop, once it knows the job's pid. The
# job must get the stop: the wrapper ends, logs it and exits 143.
test_lr56_stop_before_exec() {
  local junk env_file
  echo '# lr-56: a stop forwarded before the job has exec'"'"'d'
  junk="$(/usr/bin/perl -e 'print join(":", map { "/nx$_" } 1..60000)')"
  new_case
  mkdir -p "${CASE_DIR}/jobbin"
  # shellcheck disable=SC2016  # Expanded by the job script.
  printf '%s\n' '#!/bin/sh' 'echo $$ >"$1"' 'exec /bin/sleep 30' \
    >"${CASE_DIR}/jobbin/slowjob"
  chmod +x "${CASE_DIR}/jobbin/slowjob"
  env_file="${CASE_DIR}/env.bash"
  lr56_env "${env_file}" 'woke=??' 1 'kill -TERM $$'
  BASH_ENV="${env_file}" lr56_start "${junk}:${CASE_DIR}/jobbin" \
    svc -- slowjob "${CASE_DIR}/child.pid"
  lr_stop_finish 15
  check 'lr-56-guard: before exec: SIGTERM injected' lr56_injected
  check 'lr-56: before exec: wrapper ended by itself' lr_stop_not_killed
  check 'lr-56: before exec: exits 143' lr_stop_exited_with 143
  check 'lr-56: before exec: logged as a stop' \
    audit_has 'stopped by signal (exit 143,'
  check 'lr-56: before exec: job not left running' lr56_job_gone
  lr_stop_reap
}

# F2: with --kill-after, a stop whose trap runs as the wrapper is about to
# wait (after its loop has looked for a stop) still starts the deadline. The
# job ignores SIGTERM; a USR1 wakes the wrapper once, and SIGTERM is injected
# at its second wait.
test_lr56_stop_at_wait() {
  local env_file
  echo '# lr-56: --kill-after, a stop as the wrapper is about to wait'
  new_case
  lr_stop_job "trap 'echo TERM >>\"\$1.terms\"' TERM
trap 'echo USR1 >>\"\$1.usr1\"' USR1
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
  env_file="${CASE_DIR}/env.bash"
  lr56_env "${env_file}" 'wait\ *' 2 'kill -TERM $$'
  BASH_ENV="${env_file}" lr_stop_start svc --kill-after 2 -- \
    "${CASE_DIR}/job.sh" "${CASE_DIR}/child.pid"
  if ! lr_stop_wait_for "${CASE_DIR}/child.pid"; then
    check 'lr-56-guard: at wait: wrapper started the job' false
    lr_stop_finish 0
  else
    sleep 1
    kill -USR1 "${LR_WPID}"
    lr_stop_finish 15
    check 'lr-56-guard: at wait: SIGTERM injected' lr56_injected
    check 'lr-56-guard: at wait: the job got the USR1' \
      lr_stop_file_is "${CASE_DIR}/child.pid.usr1" USR1
    check 'lr-56: at wait: the job got the SIGTERM' \
      lr_stop_file_is "${CASE_DIR}/child.pid.terms" TERM
    check 'lr-56: at wait: wrapper ended by itself' lr_stop_not_killed
    check 'lr-56: at wait: killed at the deadline, 137' \
      lr_stop_exited_with 137
    check 'lr-56: at wait: the SIGKILL is logged' \
      audit_has 'stopped by signal, SIGKILL after 2s (exit 137, '
    check 'lr-56: at wait: job gone' lr56_job_gone
  fi
  lr_stop_reap
}

# F3: from the --kill-after SIGKILL on, USR1, USR2 and ALRM are ignored like
# HUP, INT and TERM, so none can interrupt the reap (issue #52). The traps in
# force are read as the wrapper is about to send the SIGKILL.
test_lr56_guard_at_sigkill() {
  local env_file sig
  echo '# lr-56: the traps in force at the --kill-after SIGKILL'
  new_case
  lr_stop_job "trap '' TERM
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
  env_file="${CASE_DIR}/env.bash"
  # shellcheck disable=SC2016  # Expanded by the wrapper's bash.
  lr56_env "${env_file}" 'kill\ -KILL*' 1 \
    'trap -p HUP INT TERM USR1 USR2 ALRM >"${HOME}/traps"'
  BASH_ENV="${env_file}" lr_stop_start svc --kill-after 1 -- \
    "${CASE_DIR}/job.sh" "${CASE_DIR}/child.pid"
  if ! lr_stop_wait_for "${CASE_DIR}/child.pid"; then
    check 'lr-56-guard: at SIGKILL: wrapper started the job' false
    lr_stop_finish 0
  else
    sleep 1
    kill -TERM "${LR_WPID}"
    lr_stop_finish 15
    check 'lr-56-guard: at SIGKILL: traps read' lr56_injected
    # HUP, INT and TERM were guarded before the fix already.
    for sig in HUP INT TERM; do
      check "lr-56-guard: at SIGKILL: SIG${sig} ignored" \
        grep -q -x -- "trap -- '' SIG${sig}" "${CASE_HOME}/traps"
    done
    for sig in USR1 USR2 ALRM; do
      check "lr-56: at SIGKILL: SIG${sig} ignored" \
        grep -q -x -- "trap -- '' SIG${sig}" "${CASE_HOME}/traps"
    done
    check 'lr-56-guard: at SIGKILL: exits 137' lr_stop_exited_with 137
    check 'lr-56-guard: at SIGKILL: the SIGKILL is logged' \
      audit_has 'stopped by signal, SIGKILL after 1s (exit 137, '
  fi
  lr_stop_reap
}

# F4: a stop that reaches the wrapper's trap at the last command it runs
# before it forks the job means the job never runs. That command is found by
# a first run that records the main shell's commands: it is the one just
# before the job's pid is read.
test_lr56_stop_before_fork() {
  local env_file n
  echo '# lr-56: a stop at the last command before the fork'
  new_case
  env_file="${CASE_DIR}/trace.bash"
  # shellcheck disable=SC2016  # Expanded by the wrapper's bash.
  printf '%s\n' 'set -T' \
    'trap '\''[ "${BASH_SUBSHELL}" = 0 ] && printf "%s\n" "${BASH_COMMAND}" >>"${HOME}/trace"'\'' DEBUG' \
    >"${env_file}"
  BASH_ENV="${env_file}" lr_stop_start svc -- /usr/bin/true
  lr_stop_finish 15
  n="$(/usr/bin/awk '/^pid=\$!$/ { print NR - 1; exit }' \
    "${CASE_HOME}/trace" 2>/dev/null)"
  if [ -z "${n}" ] || [ "${n}" -lt 1 ]; then
    check 'lr-56-guard: before fork: the fork found' false
    return
  fi
  new_case
  seed_counter svc 1
  # shellcheck disable=SC2016  # Expanded by the job script.
  lr_stop_job 'echo started >>"$1"'
  env_file="${CASE_DIR}/env.bash"
  lr56_env "${env_file}" '*' "${n}" 'kill -TERM $$'
  BASH_ENV="${env_file}" lr_stop_start svc -- \
    "${CASE_DIR}/job.sh" "${CASE_DIR}/ran"
  lr_stop_finish 15
  check 'lr-56-guard: before fork: SIGTERM injected' lr56_injected
  check 'lr-56: before fork: wrapper not killed' lr_stop_not_killed
  check 'lr-56: before fork: exits 143' lr_stop_exited_with 143
  check 'lr-56: before fork: logged as a stop before the job started' \
    audit_has 'stopped by signal before the job started - not counted'
  check 'lr-56: before fork: job not run' path_absent "${CASE_DIR}/ran"
  check 'lr-56: before fork: streak of 1 untouched' counter_is svc 1
}

main() {
  make_stubs
  echo "lr-56 checks (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_lr56_stop_before_exec
  test_lr56_stop_at_wait
  test_lr56_guard_at_sigkill
  test_lr56_stop_before_fork
  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
