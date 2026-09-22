#!/bin/bash
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

LABEL="${1:-}"; shift || true
[ -n "$LABEL" ] || { echo "usage: launchd-run.sh LABEL [--after N] -- cmd..." >&2; exit 64; }

ALERT_AFTER=2
while [ $# -gt 0 ]; do
  case "$1" in
    --after) ALERT_AFTER="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "launchd-run: unexpected argument $1" >&2; exit 64 ;;
  esac
done
[ $# -gt 0 ] || { echo "launchd-run: no command given" >&2; exit 64; }

STATE="$HOME/.local/state/launchd-run/$LABEL"
AUDIT="$HOME/Library/Logs/launchd-run.log"
mkdir -p "$STATE"

note() { printf '%s  %-38s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LABEL" "$*" >>"$AUDIT"; }

# Banners are attributed to Script Editor; text is interpolated into AppleScript,
# so keep it free of quotes.
notify() {
  osascript -e "display notification \"$2\" with title \"launchd: $LABEL\" subtitle \"$1\"" >/dev/null 2>&1 \
    && note "alert sent: $1 - $2" \
    || note "alert FAILED to send (osascript)"
}

started=$(date +%s)
"$@"
code=$?
elapsed=$(( $(date +%s) - started ))

fails_file="$STATE/fail-count"
prev=$(cat "$fails_file" 2>/dev/null || echo 0)

# 129/130/137/143 are SIGHUP/SIGINT/SIGKILL/SIGTERM: somebody stopped the job -
# a logout, a launchctl kill, a KeepAlive restart. That is not a failure, and it
# must not reset a real failure streak either, so it is recorded and ignored.
# Crash signals (134 SIGABRT, 138 SIGBUS, 139 SIGSEGV) still count.
case "$code" in
  129|130|137|143)
    note "stopped by signal (exit $code, ${elapsed}s) - not counted"
    exit "$code" ;;
esac

if [ "$code" -eq 0 ]; then
  rm -f "$fails_file"
  note "ok (${elapsed}s)"
  [ "$prev" -ge "$ALERT_AFTER" ] && notify "Back to normal" "succeeded after $prev failed runs"
else
  fails=$((prev + 1))
  printf '%s' "$fails" >"$fails_file"
  note "FAILED exit $code (${elapsed}s, consecutive: $fails)"
  # One bad run can be a flaky network or a host mid-deploy; a pattern cannot.
  [ "$fails" -ge "$ALERT_AFTER" ] && notify "Job failing" "exit $code on $fails consecutive runs - see the log"
fi

exit "$code"
