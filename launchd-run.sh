#!/bin/bash
#
# Wrap a launchd job so its failures are visible.
#
#   launchd-run.sh LABEL [--after N] [--kill-after SECONDS] -- command [args...]
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
# launchd's SIGKILL, ExitTimeOut seconds after its SIGTERM, also lands on the
# wrapper alone and cannot be trapped: a command that ignores SIGTERM would
# outlive the wrapper as an orphan with no outcome logged. With --kill-after
# the wrapper sends the command SIGKILL itself that many seconds after
# forwarding SIGTERM. Set it a few seconds below the plist's ExitTimeOut.
#
# Why a wrapper and not a line in each script: the jobs it guards are written in
# different languages and live in different places (a git clone, a cloud mount,
# another repo). Wrapping at the plist level guards all of them without editing
# a single working script.

set -uo pipefail

# Names the checkout this run comes from, resolved through the installed
# symlink; "unknown" if the wrapper was copied out of the repo. Sourced
# before anything else so $0 still resolves.
LIB="$(dirname "$(/usr/bin/readlink -f "$0")")/lib/version.sh"
# shellcheck source=lib/version.sh
. "${LIB}" 2>/dev/null \
  || repo_version() { echo "${REPO_VERSION:-unknown}"; }

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
  echo 'usage: launchd-run.sh LABEL [--after N] [--kill-after SECONDS]' \
    '-- cmd...' >&2
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
# Enforces --kill-after on a job that has been sent SIGTERM: returns once the
# job has exited, or sends it SIGKILL when the deadline passes first. The
# deadline is read off SECONDS, bash's clock, not counted in polls, so it
# holds on a loaded machine. SECONDS ticks in whole seconds, so one tick more
# than asked is waited for: the job gets its full time, never less, and up to
# a second more, plus one poll. The caller reaps the job, under the same
# stderr redirect as this call: bash reports a job killed by a signal on
# stderr at whichever command it runs next after the job has died.
# Globals:
#   SECONDS (restarted from zero)
# Arguments:
#   The job's pid, then the deadline in whole seconds (at most 9 digits, so
#   the sum below cannot wrap).
# Returns:
#   0 if the job was sent SIGKILL, 1 if it exited in time.
#######################################
kill_at_deadline() {
  local job="$1"
  local deadline=$(($2 + 1))
  # Counted from zero, not added to SECONDS as it stands: a SECONDS inherited
  # from the environment can be large enough to wrap the sum round to the
  # past, and the job would be killed the moment it is stopped.
  SECONDS=0
  while kill -0 "${job}"; do
    if ((SECONDS >= deadline)); then
      # From here no stop may interrupt the reap: a stop that lands just
      # after a job dies of a signal has hung bash 3.2 (issue #52).
      trap '' HUP INT TERM
      kill -KILL "${job}" || return 1
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
} 2>/dev/null

#######################################
# Parses the command line, runs the job and updates its failure streak.
# Globals:
#   LABEL, AUDIT (set here, then read-only)
# Arguments:
#   LABEL [--after N] [--kill-after SECONDS] -- command [args...]
# Outputs:
#   The job's own stdout and stderr; usage errors on stderr.
# Returns:
#   Exits with the job's status, or EX_USAGE on a malformed command line.
#######################################
main() {
  local alert_after=2 kill_after=''
  local state fails_file prev fails started pid stopped='' code elapsed sig
  local killed=''

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
      --kill-after)
        kill_after="${2:-}"
        if [[ ! "${kill_after}" =~ ^[1-9][0-9]*$ ]]; then
          usage_error \
            "--kill-after needs a positive integer, got '${kill_after}'"
        fi
        # Longer than this and the deadline sum could wrap round to the
        # past, which would kill the job the moment it is stopped.
        if ((${#kill_after} > 9)); then
          usage_error \
            "--kill-after takes at most 9 digits, got '${kill_after}'"
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
  # A state directory that cannot be made is reported where the counter is
  # written, in the audit log, not on the job's stderr.
  mkdir -p "${state}" 2>/dev/null
  rotate_audit

  # One start line per run, naming the wrapper's own checkout, so an audit
  # line maps to the commit that wrote it. A KeepAlive server that runs for
  # days leaves this line long before its outcome.
  note "started: launchd-run $(repo_version)"

  started="$(date +%s)"
  # The job runs in the background so that a stop signal reaches the wrapper's
  # trap instead of killing it outright. <&0 keeps stdin attached, which bash
  # would otherwise replace with /dev/null for a background job. One side
  # effect stays: bash starts a background job with SIGINT and SIGQUIT
  # ignored, and the job inherits that. launchd stops a job with SIGTERM and
  # then, once ExitTimeOut has passed, SIGKILL; the SIGKILL hits the wrapper
  # alone and cannot be trapped, which is what --kill-after is for.
  "$@" <&0 &
  pid=$!
  trap 'stopped=1; kill -TERM "${pid}" 2>/dev/null' HUP INT TERM
  # The braces keep bash's own "Segmentation fault ..." report of a crashed
  # job off the job's stderr.
  { wait "${pid}"; } 2>/dev/null
  code=$?
  if [[ -n "${stopped}" ]]; then
    # The trap interrupted wait with 128+signal before the job had exited.
    # Wait for the job itself and take its status whatever it is: a job that
    # handles SIGTERM and exits 0 has stopped cleanly.
    #
    # With --kill-after, a job that ignores the forwarded SIGTERM is not
    # waited for indefinitely: it is killed at the deadline, so that the wait
    # reaps it and the stop is logged before launchd's SIGKILL is due. The
    # kill and the wait share one redirect, so bash's "Killed" report of the
    # job cannot reach the job's stderr between the two.
    {
      if [[ -n "${kill_after}" ]] \
        && kill_at_deadline "${pid}" "${kill_after}"; then
        killed=1
      fi
      wait "${pid}"
    } 2>/dev/null
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

  # A stop is known from the wrapper itself having been signalled (launchd
  # signals the wrapper, never the job), not from the job's exit code: a job
  # that handles SIGTERM with any code was stopped. A stop is recorded and
  # ignored; it neither counts as a failure nor clears a real failure streak.
  # The converse also holds: 129/130/137/143 without a signal to the wrapper
  # (jetsam, the job's own timeout -s KILL, a manual kill -9) are failures
  # and are counted below.
  if [[ -n "${stopped}" ]]; then
    if [[ -n "${killed}" ]]; then
      note "stopped by signal, SIGKILL after ${kill_after}s" \
        "(exit ${code}, ${elapsed}s) - not counted"
    else
      note "stopped by signal (exit ${code}, ${elapsed}s) - not counted"
    fi
    exit "${code}"
  fi

  if ((code == 0)); then
    # A counter that cannot be cleared (a state directory left root-owned by
    # a sudo run) reads back the same streak on every success, so only a
    # streak that was really cleared is reported as a recovery.
    if rm -f "${fails_file}" 2>/dev/null; then
      note "ok (${elapsed}s)"
      if ((prev >= alert_after)); then
        notify "Back to normal" "succeeded after ${prev} failed runs"
      fi
    else
      note "ok (${elapsed}s) - cannot clear ${fails_file}"
    fi
  else
    fails=$((prev + 1))
    if { printf '%s' "${fails}" >"${fails_file}"; } 2>/dev/null; then
      note "FAILED exit ${code} (${elapsed}s, consecutive: ${fails})"
      # One bad run can be a flaky network or a host mid-deploy; a pattern
      # cannot.
      if ((fails >= alert_after)); then
        notify "Job failing" \
          "exit ${code} on ${fails} consecutive runs - see the log"
      fi
    else
      # Without a counter the streak never reaches --after and a job that
      # fails every run would never alert, so alert on every failure.
      note "FAILED exit ${code} (${elapsed}s, consecutive: unknown -" \
        "cannot write ${fails_file})"
      notify "Job failing" \
        "exit ${code}; its failure count cannot be saved - see the log"
    fi
  fi

  # A job killed by a crash signal reaches the wrapper as 128+N. Die of the
  # same signal instead of exiting 128+N, so launchd still sees a crash and
  # KeepAlive's Crashed key works as it would without the wrapper. A job that
  # itself exits 128+N cannot be told apart, and is passed on the same way.
  # The wrapper's own bash must not leave a core behind.
  if ((code > 128)); then
    sig="$(kill -l "$((code - 128))" 2>/dev/null)"
    case "${sig}" in
      ILL | TRAP | ABRT | IOT | EMT | FPE | BUS | SEGV | SYS)
        ulimit -c 0
        trap - "${sig}"
        kill -s "${sig}" "$$"
        ;;
    esac
  fi
  exit "${code}"
}

main "$@"
