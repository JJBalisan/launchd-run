#!/bin/bash
#
# Selector's extra checks for the lr-env lane (#23, #26, #30): the job's
# whole environment, every function the wrapper defines, and stdin, signals
# and exit status when HOME is unset. Loads the harness from run.sh without
# running its suite.
#
#   bash tests/lr_env_select_env.sh     # also under /bin/bash 3.2

# The harness globals come from the eval, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
eval "$(/usr/bin/sed '/^main "\$@"$/d' "$(dirname "$0")/run.sh")"

# A perl program that writes its whole environment, sorted and hex-encoded,
# to the file given first and exits with the status given second. The names
# bash itself adds to a child's environment are left out.
# shellcheck disable=SC2016  # $f, $s and the rest belong to perl.
readonly SEL_DUMP='my ($f, $s) = @ARGV;
open(my $h, ">", $f) or die;
for my $k (sort keys %ENV) {
  next if $k =~ /^(_|SHLVL|PWD|OLDPWD)$/;
  print $h unpack("H*", $k), "=", unpack("H*", $ENV{$k}), "\n";
}
close($h);
exit $s;'

# Names the caller sets in the full-environment checks: every name the
# wrapper uses, the locals of its helpers, and one of the caller's own.
readonly SEL_NAMES='REPO_ROOT LIB LABEL AUDIT EX_USAGE AUDIT_MAX_BYTES
  AUDIT_KEEP_LINES alert_after kill_after state started stopped pid code
  killed woke deadline_done fails prev fails_file elapsed sig subtitle text
  size tmp job deadline v SEL_OWN'

# A perl program that exits 9 if it started with SIGPIPE ignored.
# shellcheck disable=SC2016  # $SIG belongs to perl.
readonly SEL_PIPE='exit(($SIG{PIPE} || "") eq "IGNORE" ? 9 : 0)'

SEL_CMD=()

#######################################
# Sets SEL_CMD to an env -i command line holding only the harness's own
# variables, a chosen HOME and any extra NAME=value pairs.
# Arguments:
#   HOME: "case", "unset" or "empty"; then NAME=value pairs.
#######################################
sel_env_cmd() {
  local home="$1"
  shift
  SEL_CMD=(/usr/bin/env -i)
  case "${home}" in
    unset) ;;
    empty) SEL_CMD+=(HOME=) ;;
    *) SEL_CMD+=("HOME=${CASE_HOME}") ;;
  esac
  SEL_CMD+=("PATH=${STUB_BIN}:${SYS_PATH}")
  SEL_CMD+=("OSASCRIPT_CALLS=${CASE_DIR}/osascript.calls")
  SEL_CMD+=("REPO_VERSION=${TEST_VERSION}")
  SEL_CMD+=("$@")
}

# The job's environment through the wrapper is the one it gets run directly.
sel_same_env() { cmp -s "${CASE_DIR}/direct" "${CASE_DIR}/wrapped"; }

# Issue #23 (and #26): the job's whole environment is the caller's, with no
# name added, dropped or changed by the wrapper, whatever the values hold.
test_sel_full_env() {
  local home name i=0 vals pairs=()
  local nl=$'\n'
  # shellcheck disable=SC2016  # Meant literally: it must never run.
  vals=("ends in newlines${nl}${nl}" '-u HOME' 'a=b=c' $'\t lead \t'
    '$(touch pwned) `touch pwned` ;|&*' '' "${nl}")
  for name in ${SEL_NAMES}; do
    pairs+=("${name}=${vals[$((i % ${#vals[@]}))]}")
    i=$((i + 1))
  done
  echo '# select: the job gets exactly the caller'"'"'s environment'
  for home in case unset empty; do
    new_case
    sel_env_cmd "${home}"
    "${SEL_CMD[@]}" /usr/bin/perl -e "${SEL_DUMP}" "${CASE_DIR}/direct" 0
    (cd "${CASE_DIR}" && "${SEL_CMD[@]}" "${WRAPPER}" job -- \
      /usr/bin/perl -e "${SEL_DUMP}" "${CASE_DIR}/wrapped" 0) \
      >"${CASE_DIR}/out" 2>"${CASE_DIR}/err"
    check "select: HOME ${home}, nothing extra set: same environment" \
      sel_same_env

    new_case
    sel_env_cmd "${home}" "${pairs[@]}"
    "${SEL_CMD[@]}" /usr/bin/perl -e "${SEL_DUMP}" "${CASE_DIR}/direct" 3
    (cd "${CASE_DIR}" && "${SEL_CMD[@]}" "${WRAPPER}" job -- \
      /usr/bin/perl -e "${SEL_DUMP}" "${CASE_DIR}/wrapped" 3) \
      >"${CASE_DIR}/out" 2>"${CASE_DIR}/err"
    RC=$?
    check "select: HOME ${home}, every name set: same environment" \
      sel_same_env
    check "select: HOME ${home}, every name set: exit 3 passed" rc_is 3
    check "select: HOME ${home}, every name set: no value was run" \
      path_absent "${CASE_DIR}/pwned"
    if [ "${home}" = case ]; then
      check 'select: every name set: failure logged under the label' \
        audit_line_has 2 ' job '
      check 'select: every name set: counter is 1' counter_is job 1
    fi
  done
}

# Prints the name of every function the wrapper defines.
sel_wrapper_funcs() {
  local re='^[[:space:]]*(function[[:space:]]+)?'
  re="${re}([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\).*"
  {
    /usr/bin/sed -n -E "s/${re}/\2/p" "${WRAPPER}"
    # Defined in lib/version.sh, or on the line that falls back to it.
    echo repo_version
  } | sort -u
}

# Issue #30: every function the wrapper defines, its new helpers included,
# loses to the program of that name on PATH, with HOME set and unset.
test_sel_all_funcs() {
  local name funcs code=20 marker
  funcs="$(sel_wrapper_funcs | tr '\n' ' ')"
  echo "# select: commands named like the wrapper's functions: ${funcs}"
  check 'select: the function list holds note and main' \
    [ -n "$(echo " ${funcs}" | grep -F ' note ' | grep -F ' main ')" ]
  for name in ${funcs}; do
    code=$((code + 1))
    new_case
    marker="${CASE_DIR}/ran"
    lr_env_path_program "${name}" "${code}"
    lr_env_wrap case :: job -- "${name}" "${marker}"
    check "select: #30 ${name}: the program on PATH ran, exit ${code}" \
      lr_env_ran_with "${marker}" "${code}"
    check "select: #30 ${name}: exit ${code} logged" \
      audit_has "FAILED exit ${code} ("
    new_case
    marker="${CASE_DIR}/ran"
    lr_env_path_program "${name}" "${code}"
    lr_env_wrap unset :: job -- "${name}" "${marker}"
    check "select: #30 HOME unset: ${name}: the program ran, exit ${code}" \
      lr_env_ran_with "${marker}" "${code}"
    LR_ENV_PATH=''
  done

  echo '# select: a command that is not found'
  new_case
  lr_env_wrap case :: job -- lr-env-no-such-command
  check 'select: missing command: exit 127' rc_is 127
  check 'select: missing command: exit 127 logged' \
    audit_has 'FAILED exit 127 ('
  new_case
  lr_env_wrap unset :: job -- lr-env-no-such-command
  check 'select: HOME unset: missing command: exit 127' rc_is 127
}

# The directory holds exactly the one entry given.
sel_dir_holds_only() { [ "$(ls -A "$1")" = "$2" ]; }

# Issue #26: with HOME unset the wrapper writes nothing anywhere, passes
# stdin and SIGPIPE's default to the job, and keeps the job's exit status.
test_sel_no_home() {
  local home
  for home in unset empty; do
    echo "# select: HOME ${home}: nothing written, stdin passed"
    new_case
    mkdir -p "${CASE_DIR}/cwd"
    (cd "${CASE_DIR}/cwd" \
      && lr_env_wrap "${home}" :: job -- /usr/bin/touch made)
    check "select: HOME ${home}: the working directory holds only the job's" \
      sel_dir_holds_only "${CASE_DIR}/cwd" made
    check "select: HOME ${home}: the case HOME is untouched" \
      sel_dir_holds_only "${CASE_HOME}" Library

    new_case
    printf 'in-line\n' | lr_env_wrap "${home}" :: job -- /bin/cat
    check "select: HOME ${home}: stdin reaches the job" out_is in-line

    new_case
    lr_env_wrap "${home}" :: job -- /usr/bin/perl \
      -e "${SEL_PIPE}"
    check "select: HOME ${home}: the job starts with SIGPIPE's default" \
      rc_is 0
  done
  new_case
  lr_env_wrap case :: job -- /usr/bin/perl \
    -e "${SEL_PIPE}"
  check 'select: HOME set: the job starts with SIGPIPE'"'"'s default' rc_is 0
}

#######################################
# Like run_wrap_raw, with HOME "case" or "unset".
# Globals:
#   RC, KILLED_BY (set)
# Arguments:
#   HOME, then arguments for launchd-run.sh.
#######################################
sel_raw() {
  local home="$1"
  shift
  sel_env_cmd "${home}"
  # shellcheck disable=SC2016  # $? and $f belong to perl.
  (cd "${CASE_DIR}" \
    && "${SEL_CMD[@]}" /usr/bin/perl -e 'my $f = shift; system(@ARGV);
        open(my $h, ">", $f) or die; print $h ($? & 127);
        exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' \
      "${CASE_DIR}/killed-by" "${WRAPPER}" "$@" \
      >"${CASE_DIR}/out" 2>"${CASE_DIR}/err")
  RC=$?
  KILLED_BY="$(cat "${CASE_DIR}/killed-by" 2>/dev/null)"
}

sel_killed_by() { [ "${KILLED_BY}" = "$1" ]; }

# Issue #26: a job that crashes with HOME unset reaches the caller as the
# same crash, as it does with HOME set.
test_sel_crash_status() {
  local home
  echo '# select: a crashing job, HOME set and unset'
  for home in case unset; do
    new_case
    # shellcheck disable=SC2016  # $$ belongs to the job's own sh.
    sel_raw "${home}" job -- /bin/sh -c 'ulimit -c 0; kill -SEGV $$'
    check "select: HOME ${home}: the job's SIGSEGV reaches the caller" \
      sel_killed_by 11
  done
}

#######################################
# Starts the wrapper in the background on a job that writes its pid to
# $CASE_DIR/child.pid once its traps are set, waits for it, and sends the
# wrapper SIGTERM.
# Globals:
#   RC (set), CHILD (set to the job's pid, or empty)
# Arguments:
#   HOME, then the job's body (sh; $1 is the pid file), then NAME=value
#   pairs, then "::", then the wrapper's options.
#######################################
sel_stop() {
  local home="$1" body="$2" wpid i=0
  shift 2
  printf '#!/bin/sh\n%s\n' "${body}" >"${CASE_DIR}/job.sh"
  chmod +x "${CASE_DIR}/job.sh"
  local pairs=()
  while [ "$#" -gt 0 ] && [ "$1" != '::' ]; do
    pairs+=("$1")
    shift
  done
  shift
  sel_env_cmd "${home}" ${pairs[@]+"${pairs[@]}"}
  "${SEL_CMD[@]}" "${WRAPPER}" svc "$@" -- "${CASE_DIR}/job.sh" \
    "${CASE_DIR}/child.pid" >"${CASE_DIR}/out" 2>"${CASE_DIR}/err" &
  wpid=$!
  CHILD=''
  RC=255
  if ! lr_stop_wait_for "${CASE_DIR}/child.pid"; then
    kill -KILL "${wpid}" 2>/dev/null
    wait "${wpid}" 2>/dev/null
    return 1
  fi
  CHILD="$(cat "${CASE_DIR}/child.pid")"
  leftover_pids="${leftover_pids} ${CHILD}"
  sleep 1
  kill -TERM "${wpid}"
  {
    while kill -0 "${wpid}" && [ "${i}" -lt 300 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -KILL "${wpid}"
    wait "${wpid}"
    RC=$?
  } 2>/dev/null
}

sel_job_gone() { [ -n "${CHILD}" ] && pid_gone "${CHILD}"; }

# Issue #26 with the stop handling of PR #56: with HOME unset a stop still
# reaches the job. Issue #23: with the caller's values of main's locals set,
# a stop is still forwarded and --kill-after still fires.
test_sel_stops() {
  local body
  echo '# select: stops with HOME unset and with main'"'"'s names set'
  # shellcheck disable=SC2016  # Expanded by the job script.
  body='trap "echo term >\"${1%/*}/got-term\"; exit 0" TERM
echo $$ >"$1"
while :; do /bin/sleep 0.1; done'
  new_case
  sel_stop unset "${body}" ::
  check 'select: HOME unset: SIGTERM to the wrapper reaches the job' \
    wait_for_file "${CASE_DIR}/got-term"
  check 'select: HOME unset: the job is gone after the stop' sel_job_gone
  lr_stop_reap

  new_case
  sel_stop case "${body}" pid=1 stopped= woke=1 killed=1 deadline_done=1 \
    kill_after=1 code=0 ::
  check 'select: main'"'"'s names set: SIGTERM reaches the job' \
    wait_for_file "${CASE_DIR}/got-term"
  check 'select: main'"'"'s names set: the stop is logged' \
    audit_has 'stopped by signal (exit 0'
  check 'select: main'"'"'s names set: no counter written' counter_absent svc
  lr_stop_reap

  # shellcheck disable=SC2016  # Expanded by the job script.
  body='trap "" TERM
echo $$ >"$1"
while :; do /bin/sleep 0.1; done'
  new_case
  sel_stop case "${body}" pid=1 stopped= woke=1 killed= deadline_done=1 \
    kill_after=99 :: --kill-after 2
  check 'select: main'"'"'s names set: --kill-after 2 still fires' \
    audit_has 'SIGKILL after 2s'
  check 'select: main'"'"'s names set: the stubborn job is gone' sel_job_gone
  lr_stop_reap
}

# Differential: commands the wrapper ran before the fix still run, a path
# holding "=" and a name starting with "-" included, and the caller's values
# of names a fix might add for itself still reach the job.
test_sel_odd_commands() {
  local marker name pairs=() names
  echo '# select: odd command names and the fix'"'"'s own names'
  new_case
  marker="${CASE_DIR}/ran"
  mkdir -p "${CASE_DIR}/d=1"
  # shellcheck disable=SC2016  # $1 belongs to the program.
  printf '#!/bin/sh\necho ran >"$1"\n' >"${CASE_DIR}/d=1/prog"
  chmod +x "${CASE_DIR}/d=1/prog"
  lr_env_wrap case :: job -- "${CASE_DIR}/d=1/prog" "${marker}"
  check 'select: a command path holding "=" runs, exit 0' \
    lr_env_ran_with "${marker}" 0
  new_case
  marker="${CASE_DIR}/ran"
  lr_env_path_program -dash 0
  lr_env_wrap case :: job -- -dash "${marker}"
  check 'select: a command named "-dash" on PATH runs, exit 0' \
    lr_env_ran_with "${marker}" 0
  LR_ENV_PATH=''

  names='JOB_ENV _name _names _lr_env _lr_n launchd_run_job_env
    launchd_run_name'
  for name in ${names}; do
    pairs+=("${name}=caller")
  done
  new_case
  # shellcheck disable=SC2086  # The list is split on purpose.
  lr_env_dump_job 0 ${names}
  lr_env_wrap case "${pairs[@]}" :: job -- "${LR_ENV_JOB[@]}"
  for name in ${names}; do
    check "select: the caller's ${name} reaches the job" \
      lr_env_job_saw "${name}" caller
  done
}

main() {
  make_stubs
  echo "lr-env select checks (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_sel_full_env
  test_sel_all_funcs
  test_sel_no_home
  test_sel_crash_status
  test_sel_stops
  test_sel_odd_commands
  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
