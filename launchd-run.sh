#!/bin/bash
#
# Wrap a launchd job so its failures are visible.
#
#   launchd-run.sh LABEL [--after N] -- command [args...]
#
# Runs the command, passes its stdout/stderr and exit code straight through, and
# raises a Notification Center banner once it has failed N consecutive times
# (default 2), re-raising every run it stays broken and once more on recovery.
#
# Why a wrapper and not a line in each script: the jobs it guards are written in
# different languages and live in different places (a git clone, a cloud mount,
# another repo). Wrapping at the plist level guards all of them without editing
# a single working script.

set -uo pipefail

# Exit status for a malformed command line (EX_USAGE in sysexits.h).
readonly EX_USAGE=64

# Set once the arguments are parsed; read by note() and notify().
LABEL=''
AUDIT=''

# The job's exit status, kept global so the last line of the file can still
# pass it through if main is cut short (see there).
JOB_EXIT=0

#######################################
# Appends one timestamped line to the central audit log.
# Globals:
#   LABEL
#   AUDIT
# Arguments:
#   Message words, joined with spaces.
#######################################
note() {
  printf '%s  %-38s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${LABEL}" "$*" >>"${AUDIT}"
}

#######################################
# Raises a Notification Center banner and records the outcome in the audit log.
# Banners are attributed to Script Editor. The text is interpolated into
# AppleScript, so keep it free of double quotes.
# Globals:
#   LABEL
# Arguments:
#   Subtitle, then the banner text.
#######################################
notify() {
  local subtitle="$1"
  local text="$2"
  if osascript -e "display notification \"${text}\" with title \"launchd: ${LABEL}\" subtitle \"${subtitle}\"" >/dev/null 2>&1; then
    note "alert sent: ${subtitle} - ${text}"
  else
    note "alert FAILED to send (osascript)"
  fi
}

#######################################
# Parses the command line, runs the job and updates its failure streak.
# Globals:
#   LABEL, AUDIT (set here, then read-only)
#   JOB_EXIT (set to the job's exit status)
# Arguments:
#   LABEL [--after N] -- command [args...]
# Outputs:
#   The job's own stdout and stderr; usage errors on stderr.
# Returns:
#   Exits with the job's status, or EX_USAGE on a malformed command line.
#######################################
main() {
  local alert_after=2
  local state fails_file prev fails started code elapsed

  LABEL="${1:-}"
  shift || true
  if [[ -z "${LABEL}" ]]; then
    echo "usage: launchd-run.sh LABEL [--after N] -- cmd..." >&2
    exit "${EX_USAGE}"
  fi
  readonly LABEL

  while (($# > 0)); do
    case "$1" in
      --after)
        alert_after="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "launchd-run: unexpected argument $1" >&2
        exit "${EX_USAGE}"
        ;;
    esac
  done
  if (($# == 0)); then
    echo "launchd-run: no command given" >&2
    exit "${EX_USAGE}"
  fi

  state="${HOME}/.local/state/launchd-run/${LABEL}"
  AUDIT="${HOME}/Library/Logs/launchd-run.log"
  readonly AUDIT
  mkdir -p "${state}"

  started="$(date +%s)"
  "$@"
  code=$?
  JOB_EXIT="${code}"
  elapsed=$(($(date +%s) - started))

  fails_file="${state}/fail-count"
  prev="$(cat "${fails_file}" 2>/dev/null || echo 0)"

  # 129/130/137/143 are SIGHUP/SIGINT/SIGKILL/SIGTERM: somebody stopped the
  # job - a logout, a launchctl kill, a KeepAlive restart. That is not a
  # failure, and it must not reset a real failure streak either, so it is
  # recorded and ignored. Crash signals (134 SIGABRT, 138 SIGBUS, 139 SIGSEGV)
  # still count.
  case "${code}" in
    129 | 130 | 137 | 143)
      note "stopped by signal (exit ${code}, ${elapsed}s) - not counted"
      exit "${code}"
      ;;
  esac

  # The streak comparisons below stay on [ ]: prev comes from a file and
  # alert_after from the command line, and neither is validated yet. On a
  # non-number [ ] prints an error and is false, whereas [[ ]] and (( ))
  # would evaluate the text as arithmetic and can abort the wrapper.
  if [[ "${code}" -eq 0 ]]; then
    rm -f "${fails_file}"
    note "ok (${elapsed}s)"
    if [ "${prev}" -ge "${alert_after}" ]; then
      notify "Back to normal" "succeeded after ${prev} failed runs"
    fi
  else
    fails=$((prev + 1))
    printf '%s' "${fails}" >"${fails_file}"
    note "FAILED exit ${code} (${elapsed}s, consecutive: ${fails})"
    # One bad run can be a flaky network or a host mid-deploy; a pattern
    # cannot.
    if [ "${fails}" -ge "${alert_after}" ]; then
      notify "Job failing" "exit ${code} on ${fails} consecutive runs - see the log"
    fi
  fi

  exit "${code}"
}

main "$@"
# main always exits, except when a corrupt fail-count file (such as "12abc")
# makes the $(( )) above fail: bash then abandons main and resumes here. Pass
# the job's status through in that case too.
# shellcheck disable=SC2317  # Reachable, as above.
exit "${JOB_EXIT}"
