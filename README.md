# launchd-run

A wrapper that makes launchd job failures visible. Without it a broken job exits
1 into a log nobody reads — which is how a weekly backup here missed two Sundays
unnoticed.

```
launchd-run.sh LABEL [--after N] -- command [args...]
```

Runs the command, passes stdout, stderr and the exit code straight through, and
raises a Notification Center banner once the job has failed `N` consecutive
times (default 2), re-raising every run it stays broken and once more when it
recovers. Central audit trail in `~/Library/Logs/launchd-run.log`; per-job
counters in `~/.local/state/launchd-run/<label>/`.

## Install

```sh
./install.sh
```

Then put the wrapper in front of a job's existing `ProgramArguments`:

```
[ ~/.local/bin/launchd-run.sh, com.example.job, --after, 2, --, /bin/bash, ~/bin/job.sh ]
```

and `launchctl bootout` + `bootstrap` that agent. Daily jobs suit `--after 2`
(one flaky network night is not news); weekly ones suit `--after 1`, since a
missed weekly run is already a fortnight of drift by the time it happens twice.

## Signals are not failures

Exit codes 129, 130, 137 and 143 (SIGHUP, SIGINT, SIGKILL, SIGTERM) mean
somebody stopped the job — a logout, a `launchctl kill`, a `KeepAlive` restart.
Those are recorded and ignored: they neither raise the counter nor clear an
existing streak. Crash signals (134 SIGABRT, 138 SIGBUS, 139 SIGSEGV) still
count.

This matters for `KeepAlive` servers, which exit by signal in normal use.
Without it, two ordinary restarts look identical to two crashes.

launchd stops a job by signalling its main process, which with the wrapper in
front is the wrapper itself. The wrapper traps SIGHUP, SIGINT and SIGTERM,
forwards SIGTERM to the command, waits for it to exit and then logs the stop
(`stopped by signal`), so a `launchctl kickstart -k` leaves one audit line and
no orphaned command. A command that handles SIGTERM and exits 0 is logged as
`ok`. One side effect: the command runs as a background job of the wrapper, so
it starts with SIGINT and SIGQUIT ignored.

## Why a wrapper rather than a line in each script

The jobs it guards are written in different languages and live in different
places — a git clone, a cloud mount, another repo. Wrapping at the plist level
guards all of them without editing a single working script, and it catches
non-zero exits uniformly.

Its blind spot is the job that exits 0 having done nothing. No wrapper can see
that; the job itself has to notice. See `spicetify-autoupgrade` for that
pattern.

## Do not wrap a job that drives the GUI

macOS attributes Automation permission (`tell application "System Events" …`) to
the process launchd started. Inserting this wrapper changes that process from,
say, `python3` to `bash`, so the existing grant no longer applies and the job
blocks on a permission prompt that a background agent cannot show. A
wallpaper-setting job here hung exactly this way.

`display notification` is a *different* permission class and is unaffected —
this wrapper's own banners work fine from the same bash context.
