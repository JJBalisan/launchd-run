#!/bin/bash
#
# Select-stage checks for the lr-docs lane (#36): the exact byte boundary of
# the audit log trim. The wrapper trims only when the log is larger than
# 16777216 bytes, so a log of exactly that size is left alone and one byte
# more is trimmed to its last 100000 lines. Loads the harness from run.sh
# without running its suite.
#
#   bash tests/lr_docs_select_boundary.sh     # also under /bin/bash 3.2

# The harness globals come from the eval, which shellcheck cannot follow.
# shellcheck disable=SC2034,SC2154
eval "$(/usr/bin/sed '/^main "\$@"$/d' "$(dirname "$0")/run.sh")"

# The case's audit log is exactly this many bytes.
lr_docs_sel_bytes_are() {
  local n
  n="$(wc -c <"${CASE_HOME}/Library/Logs/launchd-run.log" | tr -d ' ')"
  [ "${n}" -eq "$1" ]
}

# Seeds 234000 lines (16748001 bytes), then one line of N-1 x's and a
# newline, so the log is 16748001 + N bytes.
lr_docs_sel_seed() {
  seed_audit_lines 234000
  awk -v n="$(($1 - 1))" 'BEGIN {
    s = sprintf("%" n "s", ""); gsub(/ /, "x", s); print s
  }' >>"${CASE_HOME}/Library/Logs/launchd-run.log"
}

test_lr_docs_sel_boundary() {
  echo '# lr-docs select #36: a log of exactly 16777216 bytes is left alone'
  new_case
  lr_docs_sel_seed 29215
  check 'lr-docs-sel: #36 seed is 16777216 bytes' \
    lr_docs_sel_bytes_are 16777216
  run_wrap job -- /usr/bin/true
  check 'lr-docs-sel: #36 at 16 MB: exit 0' rc_is 0
  check 'lr-docs-sel: #36 at 16 MB: all lines kept plus this run' \
    audit_lines_are 234003
  check 'lr-docs-sel: #36 at 16 MB: nothing about a trim' audit_lacks 'trimmed'

  echo '# lr-docs select #36: one byte more is trimmed to 100000 lines'
  new_case
  lr_docs_sel_seed 29216
  check 'lr-docs-sel: #36 seed is 16777217 bytes' \
    lr_docs_sel_bytes_are 16777217
  run_wrap job -- /usr/bin/true
  check 'lr-docs-sel: #36 past 16 MB: exit 0' rc_is 0
  check 'lr-docs-sel: #36 past 16 MB: 100000 kept, note and this run' \
    audit_lines_are 100003
  check 'lr-docs-sel: #36 past 16 MB: oldest kept seed line' \
    audit_line_has 1 'line 134002'
  check 'lr-docs-sel: #36 past 16 MB: line before it gone' \
    audit_lacks 'line 134001'
  check 'lr-docs-sel: #36 past 16 MB: filler line kept' \
    audit_line_has 100000 'xxxxxxxx'
  check 'lr-docs-sel: #36 past 16 MB: trim note' \
    audit_line_has 100001 'audit log trimmed to the last 100000 lines'
}

main() {
  make_stubs
  echo "lr-docs select checks (bash ${BASH_VERSION}) against ${WRAPPER}"
  test_lr_docs_sel_boundary
  printf '\n%d passed, %d failed\n' "${passes}" "${failures}"
  [ "${failures}" -eq 0 ]
}

main "$@"
