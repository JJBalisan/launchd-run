#!/bin/bash
#
# Extra checks for the lr-env lane (#23, #26, #30) at the edges of the job's
# command line and environment. Loads the harness from run.sh without running
# its suite.
#
#   bash tests/lr_env_s3_boundary.sh     # also under /bin/bash 3.2

# The harness globals come from the eval, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
eval "$(/usr/bin/sed '/^main "\$@"$/d' "$(dirname "$0")/run.sh")"

# Values with characters that break a naive hand-off to the job.
test_s3_awkward_values() {
  local name value i=0
  echo '# s3: awkward values of the wrapper'"'"'s names reach the job intact'
  for name in LABEL REPO_ROOT state alert_after AUDIT; do
    for value in $'two\nlines' $'trailing\n\n' '-n' '-- x' 'a=b=c' \
      "it's \"q\" \$HOME \`id\` *" ' lead and trail ' $'tab\there' 'é€'; do
      i=$((i + 1))
      new_case
      lr_env_dump_job 0 "${name}"
      lr_env_wrap case "${name}=${value}" :: job -- "${LR_ENV_JOB[@]}"
      check "s3: ${name} value #${i} reaches the job" \
        lr_env_job_saw "${name}" "${value}"
      check "s3: ${name} value #${i}: logged under the real label" \
        audit_has ' job '
    done
  done
}

# Every name the wrapper assigns is in the list it puts back.
test_s3_names_complete() {
  local script="${REPO}/launchd-run.sh" listed wanted name
  echo '# s3: the saved names cover every global and every local of main'
  listed="$(sed -n '/^launchd_run_job_env=/,/; do$/p' "${script}" \
    | tr -s ' ;' '\n' | sed -n '/^[A-Za-z_][A-Za-z_0-9]*$/p')"
  wanted="$(
    {
      sed -n 's/^readonly \([A-Za-z_]*\)=.*/\1/p;
        s/^\([A-Z][A-Z_]*\)=.*/\1/p' "${script}"
      sed -n '/^main() {$/,/^}$/{
        s/^  local //p
        s/^  \([A-Za-z_]*\)=.*/\1/p
        }' "${script}" | tr ' ' '\n' | sed 's/=.*//'
      echo REPO_ROOT
    } | sed -n '/^[A-Za-z_][A-Za-z_0-9]*$/p' | sort -u
  )"
  for name in ${wanted}; do
    case "${name}" in
      launchd_run_*) continue ;;
    esac
    check "s3: ${name} is saved at entry" \
      grep -q -x -- "${name}" <<<"${listed}"
  done
  check 's3: the list was found' [ -n "${listed}" ]
}

# env reads NAME=value and a leading dash as its own: a command that looks
# like either must still be taken as the command.
test_s3_command_shapes() {
  local marker prog
  echo '# s3: commands that look like env arguments'
  new_case
  marker="${CASE_DIR}/ran"
  prog="${CASE_DIR}/prog=x"
  # shellcheck disable=SC2016  # $1 and LABEL belong to the program.
  printf '#!/bin/sh\necho "$1 ${LABEL-unset}" >"$1"\n' >"${prog}"
  chmod +x "${prog}"
  lr_env_wrap case LABEL=mine :: job -- "${prog}" "${marker}"
  check 's3: a command path holding "=" runs' [ -e "${marker}" ]
  check 's3: ... with the caller'"'"'s LABEL' \
    grep -q -F "${marker} mine" "${marker}"
  check 's3: ... exit 0' rc_is 0

  new_case
  lr_env_wrap case :: job -- LABEL=x /usr/bin/true
  check 's3: a command word NAME=value is not run as an assignment' rc_is 127

  new_case
  lr_env_wrap case :: job -- -i /usr/bin/true
  check 's3: a command word -i is not an env option' rc_is 127
  check 's3: ... logged as a failure' audit_has 'FAILED exit 127 ('

  new_case
  lr_env_wrap case :: job -- /nonexistent/prog
  check 's3: a missing program exits 127' rc_is 127
  check 's3: ... logged as a failure' audit_has 'FAILED exit 127 ('

  new_case
  lr_env_wrap unset :: job -- /nonexistent/prog
  check 's3: HOME unset, a missing program exits 127' rc_is 127

  new_case
  # shellcheck disable=SC2016  # $# and $1 belong to the job's sh.
  lr_env_wrap case :: job -- /bin/sh -c 'echo "$#:$1"' sh '' 'a b'
  check 's3: empty and spaced arguments pass through' out_is '2:'
}

# stdin reaches the job on both paths.
test_s3_stdin() {
  local home
  echo '# s3: stdin reaches the job'
  for home in case unset; do
    new_case
    printf 'piped-in\n' >"${CASE_DIR}/in"
    lr_env_wrap "${home}" :: job -- /bin/cat <"${CASE_DIR}/in"
    check "s3: HOME ${home}: stdin read by the job" out_is piped-in
  done
}

# Nothing of the wrapper's is left in the job's environment on the HOME-less
# path, and the job's own variables are not disturbed.
test_s3_no_home_environment() {
  echo '# s3: HOME unset: environment as started'
  new_case
  lr_env_dump_job 0 HOME LABEL state REPO_ROOT launchd_run_name
  lr_env_wrap unset :: job -- "${LR_ENV_JOB[@]}"
  check 's3: HOME stays unset' lr_env_job_saw HOME unset
  check 's3: no LABEL appears' lr_env_job_saw LABEL unset
  check 's3: no state appears' lr_env_job_saw state unset
  check 's3: no REPO_ROOT appears' lr_env_job_saw REPO_ROOT unset
  check 's3: the wrapper'"'"'s own helper name does not appear' \
    lr_env_job_saw launchd_run_name unset
  new_case
  lr_env_wrap empty :: job -- /usr/bin/true
  check 's3: HOME empty: no audit file written' \
    path_absent "${CASE_HOME}/Library/Logs/launchd-run.log"
  check 's3: HOME empty: one warning line' lr_env_one_warning
}

main() {
  make_stubs
  echo "lr-env s3 checks (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_s3_awkward_values
  test_s3_names_complete
  test_s3_command_shapes
  test_s3_stdin
  test_s3_no_home_environment
  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
