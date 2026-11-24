#!/bin/bash
#
# Selector's extra checks for the lr-stop lane (#27, #37, #25): signals at
# points the main suite does not reach. Loads the harness from run.sh without
# running its suite.
#
#   bash tests/lr_stop_select_signals.sh     # also under /bin/bash 3.2

# The harness globals come from the eval, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
eval "$(/usr/bin/sed '/^main "\$@"$/d' "$(dirname "$0")/run.sh")"

lr_sel_clear_gate() {
  LR_PATH_PREFIX=''
  LR_GATE_CMD=''
  LR_GATE_ARG=''
}

# USR1, QUIT and PIPE before the job is forked neither kill the wrapper nor
# lose the run: none of them is a stop.
test_sel_before_fork() {
  local sig marker what
  echo '# select: a non-stop signal before the job is forked'
  for sig in USR1 QUIT PIPE; do
    what="SIG${sig} during mkdir"
    new_case
    seed_counter svc 1
    marker="${CASE_DIR}/ran"
    lr_stop_gate mkdir ''
    lr_stop_start svc -- /usr/bin/touch "${marker}"
    if ! lr_stop_wait_for "${CASE_DIR}/ready"; then
      check "select-guard: ${what}: wrapper reached the gate" false
      : >"${CASE_DIR}/go"
      lr_stop_finish 20
    else
      kill "-${sig}" "${LR_WPID}"
      : >"${CASE_DIR}/go"
      lr_stop_finish 20
      check "select: ${what}: wrapper not killed by it" lr_stop_not_killed
      check "select: ${what}: outcome logged" audit_has 'ok ('
      check "select: ${what}: exits 0" lr_stop_exited_with 0
    fi
    lr_sel_clear_gate
  done
}

# USR1 and TERM after the job has ended, while the wrapper reads the fail
# counter, do not kill it or lose the outcome line.
test_sel_bookkeeping() {
  local sig what
  echo '# select: a signal during the bookkeeping after the job'
  for sig in USR1 ALRM TERM; do
    what="SIG${sig} while reading the counter"
    new_case
    seed_counter svc 1
    lr_stop_gate cat "$(counter_file svc)"
    lr_stop_start svc -- /bin/sh -c 'exit 3'
    if ! lr_stop_wait_for "${CASE_DIR}/ready"; then
      check "select-guard: ${what}: wrapper reached the gate" false
      : >"${CASE_DIR}/go"
      lr_stop_finish 20
    else
      kill "-${sig}" "${LR_WPID}"
      : >"${CASE_DIR}/go"
      lr_stop_finish 20
      check "select: ${what}: wrapper not killed by it" lr_stop_not_killed
      check "select: ${what}: exits 3" lr_stop_exited_with 3
      check "select: ${what}: failure logged and counted" \
        audit_has 'FAILED exit 3 ('
      check "select: ${what}: streak now 2" counter_is svc 2
    fi
    lr_sel_clear_gate
  done
}

# A forwarded USR1 is not a stop: a job that then exits 0 is a success and
# clears the streak; two USR1s both reach the job.
test_sel_usr1_not_a_stop() {
  echo '# select: USR1 is not a stop'
  new_case
  seed_counter svc 1
  lr_stop_job "trap 'echo USR1 >\"\$1.got\"; exit 0' USR1
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
  if ! lr_stop_start_job; then
    check 'select-guard: USR1 then exit 0: wrapper started the job' false
    lr_stop_finish 0
  else
    kill -USR1 "${LR_WPID}"
    lr_stop_finish 20
    check 'select: USR1 then exit 0: job got it' \
      lr_stop_file_is "${CASE_DIR}/child.pid.got" USR1
    check 'select: USR1 then exit 0: exits 0' lr_stop_exited_with 0
    check 'select: USR1 then exit 0: logged ok' audit_has 'ok ('
    check 'select: USR1 then exit 0: not logged as a stop' \
      audit_lacks 'stopped by signal'
    check 'select: USR1 then exit 0: streak cleared' counter_absent svc
  fi
  lr_stop_reap

  new_case
  lr_stop_job "n=0
trap 'n=\$((n + 1)); echo USR1 >>\"\$1.got\"
if [ \"\$n\" -ge 2 ]; then exit 6; fi' USR1
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
  if ! lr_stop_start_job; then
    check 'select-guard: two USR1s: wrapper started the job' false
    lr_stop_finish 0
  else
    kill -USR1 "${LR_WPID}"
    lr_stop_wait_lines "${CASE_DIR}/child.pid.got" 1
    kill -USR1 "${LR_WPID}" 2>/dev/null
    lr_stop_finish 20
    check 'select: two USR1s: both reached the job' \
      lr_stop_lines_are "${CASE_DIR}/child.pid.got" 2
    check "select: two USR1s: the job's exit 6 passed through" \
      lr_stop_exited_with 6
    check 'select: two USR1s: logged as a failure' audit_has 'FAILED exit 6 ('
  fi
  lr_stop_reap
}

# After a stop, a job that exits 127 has its own 127 logged and returned.
test_sel_stop_exit_127() {
  echo '# select: a stopped job that exits 127'
  new_case
  lr_stop_job "trap 'exit 127' TERM
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
  if ! lr_stop_start_job; then
    check 'select-guard: stop then 127: wrapper started the job' false
    lr_stop_finish 0
  else
    kill -TERM "${LR_WPID}"
    lr_stop_finish 20
    check 'select: stop then 127: exits 127' lr_stop_exited_with 127
    check 'select: stop then 127: logged with 127' \
      audit_has 'stopped by signal (exit 127,'
  fi
  lr_stop_reap
}

# With --kill-after, a USR1 or ALRM during the deadline wait reaches the job
# and does not cut the deadline short or stretch it away.
test_sel_kill_after_forward() {
  local sig
  echo '# select: a forwarded signal during the --kill-after wait'
  for sig in USR1 ALRM; do
    new_case
    lr_stop_job "trap 'echo TERM >>\"\$1.terms\"' TERM
trap 'echo ${sig} >\"\$1.got\"' ${sig}
echo \$\$ >\"\$1\"
while :; do /bin/sleep 0.1; done"
    if ! lr_stop_start_job --kill-after 3; then
      check "select-guard: --kill-after ${sig}: wrapper started the job" false
      lr_stop_finish 0
    else
      kill -TERM "${LR_WPID}"
      lr_stop_wait_lines "${CASE_DIR}/child.pid.terms" 1
      kill "-${sig}" "${LR_WPID}" 2>/dev/null
      lr_stop_finish 30
      check "select: --kill-after ${sig}: the job got it" \
        lr_stop_file_is "${CASE_DIR}/child.pid.got" "${sig}"
      check "select: --kill-after ${sig}: killed at the deadline, 137" \
        lr_stop_exited_with 137
      check "select: --kill-after ${sig}: the SIGKILL is logged" \
        audit_has 'stopped by signal, SIGKILL after 3s (exit 137, '
    fi
    lr_stop_reap
  done
}

# A signal that cuts the wait short just as the job exits: the job signals
# the wrapper and exits at once, with 9 or with 127 (which bash also uses
# for "not a child"). The wrapper must log and return that status from
# the wait that reaps the job, not the 128+N of the wait the signal cut short.
# A BASH_ENV file makes the wrapper pause for half a second after every wait
# returns, as a loaded machine may, so that the job is gone (and reaped by
# bash in the background) before the wrapper looks at it again.
test_sel_signal_as_job_exits() {
  local sig i ec what env_file
  echo '# select: a signal to the wrapper as the job exits'
  env_file="${TMP_ROOT}/pause-after-wait.bash"
  # shellcheck disable=SC2016  # Expanded by the wrapper's bash.
  printf '%s\n' 'set -T' '_lr_prev=""' \
    'trap '\''case "${_lr_prev}" in wait*) /bin/sleep 0.5 ;; esac
_lr_prev="${BASH_COMMAND}"'\'' DEBUG' >"${env_file}"
  for ec in 9 127; do
    for sig in USR1 TERM; do
      for i in 1 2 3; do
        what="SIG${sig} as the job exits ${ec} (${i})"
        new_case
        lr_stop_job "trap '' ${sig}
echo \$\$ >\"\$1\"
/bin/sleep 1
kill -${sig} \$PPID
exit ${ec}"
        BASH_ENV="${env_file}" lr_stop_start svc -- \
          "${CASE_DIR}/job.sh" "${CASE_DIR}/child.pid"
        lr_stop_finish 20
        check "select: ${what}: exits ${ec}" lr_stop_exited_with "${ec}"
        check "select: ${what}: logged exit ${ec}" audit_has "exit ${ec}"
        lr_stop_reap
      done
    done
  done
}

# A stop just after the fork, before the wrapper has read $!: a BASH_ENV file
# makes the wrapper SIGTERM itself as it is about to read it. The job must
# still get its SIGTERM and the wrapper must end with the run logged.
test_sel_stop_after_fork() {
  local i env_file
  echo '# select: a stop between the fork and the pid'
  env_file="${TMP_ROOT}/stop-at-pid.bash"
  # shellcheck disable=SC2016  # Expanded by the wrapper's bash.
  printf '%s\n' 'set -T' \
    'trap '\''case "${BASH_COMMAND}" in *=\$!) kill -TERM $$ ;; esac'\'' DEBUG' \
    >"${env_file}"
  for i in 1 2 3 4 5; do
    new_case
    lr_stop_job "echo \$\$ >\"\$1\"
exec /bin/sleep 30"
    BASH_ENV="${env_file}" lr_stop_start svc -- \
      "${CASE_DIR}/job.sh" "${CASE_DIR}/child.pid"
    lr_stop_finish 20
    check "select: stop at the pid (${i}): wrapper not killed" \
      lr_stop_not_killed
    check "select: stop at the pid (${i}): logged as a stop" \
      audit_has 'stopped by signal'
    lr_stop_reap
  done
}

# A USR1 just after a wait that has already reaped the job: a BASH_ENV file
# makes the wrapper send itself one USR1 right after its first wait returns.
# The wrapper waits again, and that wait must give back the job's own status,
# 0, 9 or 127, not "not a child".
test_sel_signal_after_reap() {
  local ec env_file
  echo '# select: a USR1 just after the wait that reaped the job'
  env_file="${TMP_ROOT}/usr1-after-wait.bash"
  # shellcheck disable=SC2016  # Expanded by the wrapper's bash.
  printf '%s\n' 'set -T' '_lr_prev="" _lr_sent=""' \
    'trap '\''case "${_lr_prev}" in wait*)
  if [ -z "${_lr_sent}" ]; then _lr_sent=1; kill -USR1 $$; fi ;; esac
_lr_prev="${BASH_COMMAND}"'\'' DEBUG' >"${env_file}"
  for ec in 0 9 127; do
    new_case
    lr_stop_job "echo \$\$ >\"\$1\"
/bin/sleep 1
exit ${ec}"
    BASH_ENV="${env_file}" lr_stop_start svc -- \
      "${CASE_DIR}/job.sh" "${CASE_DIR}/child.pid"
    lr_stop_finish 20
    check "select: USR1 after the reap, job exits ${ec}: exits ${ec}" \
      lr_stop_exited_with "${ec}"
    if [ "${ec}" -eq 0 ]; then
      check 'select: USR1 after the reap, job exits 0: logged ok' \
        audit_has 'ok ('
    else
      check "select: USR1 after the reap, job exits ${ec}: logged" \
        audit_has "FAILED exit ${ec} ("
    fi
    lr_stop_reap
  done
}

main() {
  make_stubs
  echo "lr-stop select checks (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_sel_before_fork
  test_sel_bookkeeping
  test_sel_usr1_not_a_stop
  test_sel_stop_exit_127
  test_sel_kill_after_forward
  test_sel_signal_as_job_exits
  test_sel_stop_after_fork
  test_sel_signal_after_reap
  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
