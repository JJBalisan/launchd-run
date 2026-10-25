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
# Under launchd the wrapper is the job's main process, so a stop (launchctl
# kill, bootout, logout, a KeepAlive restart) signals the wrapper, not the
# command. SIGHUP, SIGINT and SIGTERM are therefore forwarded to the command
# as SIGTERM, and the stop is logged once the command has exited.
#
# Why a wrapper and not a line in each script: the jobs it guards are written in
# different languages and live in different places (a git clone, a cloud mount,
# another repo). Wrapping at the plist level guards all of them without editing
# a single working script.

set -uo pipefail

# Exit status for a malformed command line (EX_USAGE in sysexits.h).
readonly EX_USAGE=64

# The audit log is trimmed to its last AUDIT_KEEP_LINES lines once it passes
# AUDIT_MAX_BYTES: roughly 15,000 lines, or two years at the usual rate.
readonly AUDIT_MAX_BYTES=1048576
readonly AUDIT_KEEP_LINES=5000

# Set once the arguments are parsed; read by note() and notify().
LABEL=''
AUDIT=''

#######################################
# Reports a malformed command line on stderr and exits with EX_USAGE.
# Arguments:
#   The complaint.
#######################################
usage_error() {
  echo "launchd-run: $*" >&2
  echo 'usage: launchd-run.sh LABEL [--after N] -- cmd...' >&2
  exit "${EX_USAGE}"
}

#######################################
# Appends one timestamped line to the central audit log.
# Globals:
#   LABEL
#   AUDIT
# Arguments:
#   Message words, joined with spaces.
#######################################
note() {
  printf '%s  %-38s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${LABEL}" "$*" \
    >>"${AUDIT}"
}

#######################################
# Trims the audit log to its last AUDIT_KEEP_LINES lines once it has grown
# past AUDIT_MAX_BYTES. The trimmed copy is written beside the log and renamed
# over it, so a reader never sees a torn file; a line another job appends
# during the rename can be lost, which is accepted. The trim is noted in the
# log so the gap is explained.
# Globals:
#   AUDIT
#######################################
rotate_audit() {
  local size tmp
  size="$(/usr/bin/stat -f%z "${AUDIT}" 2>/dev/null)" || return 0
  ((size > AUDIT_MAX_BYTES)) || return 0
  tmp="${AUDIT}.$$"
  if tail -n "${AUDIT_KEEP_LINES}" "${AUDIT}" >"${tmp}" \
    && /bin/mv -f "${tmp}" "${AUDIT}"; then
    note "audit log trimmed to the last ${AUDIT_KEEP_LINES} lines"
  else
    rm -f "${tmp}"
  fi
}

#######################################
# Raises a Notification Center banner and records the outcome in the audit log.
# Banners are attributed to Script Editor. The text reaches AppleScript as
# argv rather than being spliced into the source, so any characters are fine.
# Globals:
#   LABEL
# Arguments:
#   Subtitle, then the banner text.
#######################################
notify() {
  local subtitle="$1"
  local text="$2"
  if osascript -e 'on run argv' \
    -e 'set {msg, ttl, sub} to argv' \
    -e 'display notification msg with title ttl subtitle sub' \
    -e 'end run' -- "${text}" "launchd: ${LABEL}" "${subtitle}" \
    >/dev/null 2>&1; then
    note "alert sent: ${subtitle} - ${text}"
  else
    note "alert FAILED to send (osascript)"
  fi
}

#######################################
# Parses the command line, runs the job and updates its failure streak.
# Globals:
#   LABEL, AUDIT (set here, then read-only)
# Arguments:
#   LABEL [--after N] -- command [args...]
# Outputs:
#   The job's own stdout and stderr; usage errors on stderr.
# Returns:
#   Exits with the job's status, or EX_USAGE on a malformed command line.
#######################################
main() {
  local alert_after=2
  local state fails_file prev fails started pid stopped='' code elapsed

  LABEL="${1:-}"
  shift || true
  if [[ -z "${LABEL}" ]]; then
    usage_error 'no label given'
  fi
  readonly LABEL

  while (($# > 0)); do
    case "$1" in
      --after)
        alert_after="${2:-}"
        if [[ ! "${alert_after}" =~ ^[1-9][0-9]*$ ]]; then
          usage_error "--after needs a positive integer, got '${alert_after}'"
        fi
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        usage_error "unexpected argument $1"
        ;;
    esac
  done
  if (($# == 0)); then
    usage_error 'no command given'
  fi

  state="${HOME}/.local/state/launchd-run/${LABEL}"
  AUDIT="${HOME}/Library/Logs/launchd-run.log"
  readonly AUDIT
  mkdir -p "${state}"
  rotate_audit

  started="$(date +%s)"
  # The job runs in the background so that a stop signal reaches the wrapper's
  # trap instead of killing it outright. <&0 keeps stdin attached, which bash
  # would otherwise replace with /dev/null for a background job. One side
  # effect stays: bash starts a background job with SIGINT and SIGQUIT
  # ignored, and the job inherits that; launchd only ever sends SIGTERM.
  "$@" <&0 &
  pid=$!
  trap 'stopped=1; kill -TERM "${pid}" 2>/dev/null' HUP INT TERM
  wait "${pid}"
  code=$?
  if [[ -n "${stopped}" ]]; then
    # The trap interrupted wait with 128+signal before the job had exited.
    # Wait for the job itself and take its status whatever it is: a job that
    # handles SIGTERM and exits 0 has stopped cleanly.
    wait "${pid}"
    code=$?
  fi
  # The job is done; a further stop must not cut the bookkeeping short.
  trap '' HUP INT TERM
  elapsed=$(($(date +%s) - started))

  # Anything but a plain decimal (so no leading zero, which $(( )) would read
  # as octal) means the counter is missing or corrupt: start the streak over.
  fails_file="${state}/fail-count"
  prev="$(cat "${fails_file}" 2>/dev/null)"
  if [[ ! "${prev}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    prev=0
  fi

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

  if ((code == 0)); then
    rm -f "${fails_file}"
    note "ok (${elapsed}s)"
    if ((prev >= alert_after)); then
      notify "Back to normal" "succeeded after ${prev} failed runs"
    fi
  else
    fails=$((prev + 1))
    printf '%s' "${fails}" >"${fails_file}"
    note "FAILED exit ${code} (${elapsed}s, consecutive: ${fails})"
    # One bad run can be a flaky network or a host mid-deploy; a pattern
    # cannot.
    if ((fails >= alert_after)); then
      notify "Job failing" \
        "exit ${code} on ${fails} consecutive runs - see the log"
    fi
  fi

  exit "${code}"
}

main "$@"
