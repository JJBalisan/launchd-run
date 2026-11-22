#!/bin/bash
#
# Verify-stage checks for the lr-docs lane (#36): the audit log is trimmed
# to its last 100000 lines once it passes 16 MB (16777216 bytes), and a log
# just under that size is left alone. Runs the suite's own rotation test
# too, so this file holds every check of the lane. Loads the harness from
# run.sh without running its suite.
#
#   bash tests/lr_docs_verify_rotation.sh     # also under /bin/bash 3.2

# The harness globals come from the eval, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
eval "$(/usr/bin/sed '/^main "\$@"$/d' "$(dirname "$0")/run.sh")"

# The case's audit log is exactly this many bytes.
lr_docs_audit_bytes_are() {
  local n
  n="$(wc -c <"${CASE_HOME}/Library/Logs/launchd-run.log" | tr -d ' ')"
  [ "${n}" -eq "$1" ]
}

test_lr_docs_36() {
  echo '# lr-docs #36: a log just under 16 MB is left alone'
  new_case
  # 16748001 bytes: under 16777216, over 16000000.
  seed_audit_lines 234000
  check 'lr-docs: #36 seed is 16748001 bytes' lr_docs_audit_bytes_are 16748001
  run_wrap job -- /usr/bin/true
  check 'lr-docs: #36 under 16 MB: exit 0' rc_is 0
  check 'lr-docs: #36 under 16 MB: all lines kept plus this run' \
    audit_lines_are 234002
  check 'lr-docs: #36 under 16 MB: first line intact' \
    audit_line_has 1 'line 00001'
  check 'lr-docs: #36 under 16 MB: nothing about a trim' audit_lacks 'trimmed'
}

main() {
  make_stubs
  echo "lr-docs verify checks (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_log_rotation
  test_lr_docs_36
  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
