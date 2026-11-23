#!/bin/bash
#
# Tests which runner each CI trigger gets.
#
#   bash tests/ci_runner.sh    # also runs under /bin/bash 3.2
#
# A pull_request runs on hosted macos-latest; only a push to main may use the
# runner that vars.CI_RUNNER names. Every runs-on in the workflow is evaluated
# for each trigger, with CI_RUNNER set and unset, by a small evaluator of the
# expression syntax a runs-on uses here: string literals, the contexts
# github.event_name and vars.CI_RUNNER, ==, !=, !, &&, || and parentheses.
# Anything else fails the test instead of being skipped.
#
# CI_WORKFLOW points the suite at another workflow file (used to check that
# the tests catch deliberately wrong ones). The default is the repo's ci.yml.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO
readonly WORKFLOW="${CI_WORKFLOW:-${REPO}/.github/workflows/ci.yml}"
failures=0

# Evaluator state. A value is typed by its prefix: "s:<text>" a string,
# "b:true" or "b:false" a boolean.
TOKENS=()
NTOK=0
POS=0
VALUE=''
EVENT=''
RUNNER=''

#######################################
# Prints an evaluator error to stderr and fails.
# Arguments:
#   The message.
#######################################
bad() {
  printf 'ci_runner: %s\n' "$1" >&2
  return 1
}

#######################################
# Splits an expression into TOKENS and NTOK.
# Arguments:
#   The expression, without ${{ }}.
#######################################
tokenize() {
  local s="$1" str_re="^'(([^']|'')*)'(.*)$"
  local id_re='^([A-Za-z_][A-Za-z0-9_.-]*)(.*)$'
  TOKENS=()
  NTOK=0
  while [[ -n "${s}" ]]; do
    case "${s}" in
      ' '*) s="${s:1}" ;;
      '=='* | '!='* | '&&'* | '||'*)
        TOKENS[NTOK]="${s:0:2}"
        s="${s:2}"
        NTOK=$((NTOK + 1))
        ;;
      '!'* | '('* | ')'*)
        TOKENS[NTOK]="${s:0:1}"
        s="${s:1}"
        NTOK=$((NTOK + 1))
        ;;
      *)
        if [[ "${s}" =~ ${str_re} ]]; then
          TOKENS[NTOK]="'${BASH_REMATCH[1]}'"
          s="${BASH_REMATCH[3]}"
        elif [[ "${s}" =~ ${id_re} ]]; then
          TOKENS[NTOK]="${BASH_REMATCH[1]}"
          s="${BASH_REMATCH[2]}"
        else
          bad "cannot read expression at: ${s}" || return 1
        fi
        NTOK=$((NTOK + 1))
        ;;
    esac
  done
}

#######################################
# Succeeds when a value is truthy: GitHub treats '' and false as falsy.
# Arguments:
#   A typed value.
#######################################
truthy() { [[ "$1" != 's:' && "$1" != 'b:false' ]]; }

#######################################
# Parses a primary: a literal, a context, or a parenthesised expression.
# Globals:
#   TOKENS, POS, VALUE, EVENT, RUNNER
#######################################
parse_primary() {
  local tok="${TOKENS[POS]:-}" text
  POS=$((POS + 1))
  case "${tok}" in
    '(')
      parse_or || return 1
      [[ "${TOKENS[POS]:-}" == ')' ]] || bad 'missing )' || return 1
      POS=$((POS + 1))
      ;;
    "'"*)
      text="${tok:1:${#tok}-2}"
      VALUE="s:${text//\'\'/\'}"
      ;;
    github.event_name) VALUE="s:${EVENT}" ;;
    # An unset variable reads as the empty string.
    vars.CI_RUNNER) VALUE="s:${RUNNER}" ;;
    *) bad "unsupported token: ${tok:-end of expression}" ;;
  esac
}

#######################################
# Parses ! (logical not).
#######################################
parse_not() {
  if [[ "${TOKENS[POS]:-}" == '!' ]]; then
    POS=$((POS + 1))
    parse_not || return 1
    if truthy "${VALUE}"; then VALUE='b:false'; else VALUE='b:true'; fi
  else
    parse_primary
  fi
}

#######################################
# Parses == and !=, which compare strings ignoring case.
#######################################
parse_eq() {
  parse_not || return 1
  local left="${VALUE}" op="${TOKENS[POS]:-}" same
  [[ "${op}" == '==' || "${op}" == '!=' ]] || return 0
  POS=$((POS + 1))
  parse_not || return 1
  [[ "${left}" == s:* && "${VALUE}" == s:* ]] \
    || bad "${op} on a non-string" || return 1
  left="$(printf '%s' "${left}" | tr '[:upper:]' '[:lower:]')"
  same="$(printf '%s' "${VALUE}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${left}" == "${same}" && "${op}" == '==' ]] \
    || [[ "${left}" != "${same}" && "${op}" == '!=' ]]; then
    VALUE='b:true'
  else
    VALUE='b:false'
  fi
}

#######################################
# Parses &&: the left value if falsy, else the right one.
#######################################
parse_and() {
  parse_eq || return 1
  local left="${VALUE}"
  while [[ "${TOKENS[POS]:-}" == '&&' ]]; do
    POS=$((POS + 1))
    parse_eq || return 1
    truthy "${left}" && left="${VALUE}"
  done
  VALUE="${left}"
}

#######################################
# Parses ||: the left value if truthy, else the right one.
#######################################
parse_or() {
  parse_and || return 1
  local left="${VALUE}"
  while [[ "${TOKENS[POS]:-}" == '||' ]]; do
    POS=$((POS + 1))
    parse_and || return 1
    truthy "${left}" || left="${VALUE}"
  done
  VALUE="${left}"
}

#######################################
# Prints the runner a runs-on value gives for one trigger.
# Arguments:
#   The runs-on value, the event name, and CI_RUNNER ('' for unset).
# Outputs:
#   The runner label to stdout; errors to stderr.
#######################################
runner_for() {
  local raw="$1" expr_re='^\$\{\{(.*)\}\}$'
  EVENT="$2"
  RUNNER="$3"
  if [[ ! "${raw}" =~ ${expr_re} ]]; then
    raw="${raw#[\'\"]}"
    printf '%s\n' "${raw%[\'\"]}"
    return 0
  fi
  tokenize "${BASH_REMATCH[1]}" || return 1
  POS=0
  parse_or || return 1
  ((POS == NTOK)) || bad "unexpected token: ${TOKENS[POS]}" || return 1
  [[ "${VALUE}" == s:* ]] || bad "runs-on gives ${VALUE}" || return 1
  printf '%s\n' "${VALUE#s:}"
}

#######################################
# Records one assertion: the runner for a trigger.
# Arguments:
#   The runs-on value, event name, CI_RUNNER, and the runner it must give.
#######################################
expect() {
  local got
  got="$(runner_for "$1" "$2" "$3")"
  if [[ "${got}" == "$4" ]]; then
    printf 'ok    %s, CI_RUNNER=%s: %s\n' "$2" "${3:-unset}" "$4"
  else
    printf 'FAIL  %s, CI_RUNNER=%s: want %s, got %s (runs-on: %s)\n' \
      "$2" "${3:-unset}" "$4" "${got:-nothing}" "$1"
    failures=$((failures + 1))
  fi
}

main() {
  local line value found=0
  [[ -f "${WORKFLOW}" ]] || {
    printf 'FAIL  no workflow at %s\n' "${WORKFLOW}"
    exit 1
  }
  while IFS= read -r line; do
    value="${line#*runs-on:}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    found=$((found + 1))
    expect "${value}" pull_request self-hosted macos-latest
    expect "${value}" pull_request '' macos-latest
    expect "${value}" push self-hosted self-hosted
    expect "${value}" push '' macos-latest
  done < <(grep -E '^[[:space:]]*runs-on:' "${WORKFLOW}")
  if ((found == 0)); then
    printf 'FAIL  no runs-on in %s\n' "${WORKFLOW}"
    failures=$((failures + 1))
  fi
  if ((failures > 0)); then
    printf '%d failure(s)\n' "${failures}"
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
