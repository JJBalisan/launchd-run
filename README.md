# launchd-run

A wrapper that makes launchd job failures visible. Without it a broken job exits
1 into a log nobody reads — which is how a weekly backup here missed two Sundays
unnoticed.

```text
launchd-run.sh LABEL [--after N] [--kill-after SECONDS] -- command [args...]
```

Runs the command, passes stdout, stderr and the exit code straight through, and
raises a Notification Center banner once the job has failed `N` consecutive
times (default 2), re-raising every run it stays broken and once more when it
recovers. `N` must be a positive integer; anything else is a usage error
(exit 64) and the command is not run. Central audit trail in
`~/Library/Logs/launchd-run.log`: every run writes a start line,
`started: launchd-run <version>`, naming the wrapper's own checkout (see
"Releasing"), then an outcome line; per-job counters in
`~/.local/state/launchd-run/<label>/`. A counter file that does not hold a
plain decimal number reads as 0, so a corrupt one restarts the streak rather
than breaking the wrapper. A counter that cannot be written at all (say, a
root-owned `~/.local/state`) raises a banner on every failure instead, and one
that cannot be cleared raises no "Back to normal" banner. `--kill-after` is
for a command that ignores SIGTERM; see
["A command that ignores SIGTERM"](#a-command-that-ignores-sigterm).

## Install

```sh
./install.sh
```

Then put the wrapper in front of a job's existing `ProgramArguments`:

```text
[ ~/.local/bin/launchd-run.sh, com.example.job, --after, 2, --, /bin/bash, ~/bin/job.sh ]
```

and `launchctl bootout` + `bootstrap` that agent. Daily jobs suit `--after 2`
(one flaky network night is not news); weekly ones suit `--after 1`, since a
missed weekly run is already a fortnight of drift by the time it happens twice.

## Signals are not failures

A stop is recognised by the wrapper itself being signalled (SIGHUP, SIGINT or
SIGTERM: a logout, a `launchctl kill` or `kickstart -k`, a `KeepAlive`
restart), whatever exit code the job then returns. A stop is recorded and
ignored: it neither raises the counter nor clears an existing streak.

The exit code alone never marks a stop. A job that dies of SIGKILL or SIGTERM
(137, 143) while the wrapper was not signalled was killed by something else
(memory pressure, its own `timeout -s KILL`, a manual `kill -9`), and counts as
a failure. Crash signals (134 SIGABRT, 138 SIGBUS, 139 SIGSEGV) also count, and
the wrapper then dies of the same signal rather than exiting with the code, so
launchd still sees a crash and `KeepAlive`'s `Crashed` key works.

This matters for `KeepAlive` servers, which exit by signal in normal use.
Without it, two ordinary restarts look identical to two crashes.

launchd stops a job by signalling its main process, which with the wrapper in
front is the wrapper itself. The wrapper traps SIGHUP, SIGINT and SIGTERM,
forwards SIGTERM to the command, waits for it to exit and then logs the stop
(`stopped by signal`), so a `launchctl kickstart -k` leaves one audit line and
no orphaned command, provided the command exits on SIGTERM (the next section
covers one that does not). A command that handles SIGTERM is logged as stopped
whatever code it exits with, 0 or 1 included. Further SIGHUP, SIGINT or
SIGTERM during the shutdown are forwarded as SIGTERM again; the wrapper logs
and exits only once the command has exited, with the command's own status.
The traps are in place before the command is forked. A stop that arrives
before it has started means it is never started: the wrapper logs
`stopped by signal before the job started - not counted`, leaves the counter
alone and exits with 128 plus the signal number.

Other signals sent to the wrapper do not end it either:

- SIGUSR1, SIGUSR2 and SIGALRM are passed on to the command as themselves, and
  the wrapper keeps waiting.
- SIGPIPE is ignored by the wrapper (the command keeps its default).
- SIGQUIT is ignored by the wrapper, as it is by the command (below).
- SIGSTOP cannot be trapped: it pauses only the wrapper, not the command, and
  the wrapper carries on when it is continued.

One side effect: the command runs as a background job of the wrapper, so it
starts with SIGINT and SIGQUIT ignored.

## A command that ignores SIGTERM

To stop a job, launchd sends SIGTERM to its main process and, if that process
is still there `ExitTimeOut` seconds later, SIGKILL. With the wrapper in front,
both land on the wrapper. It forwards the SIGTERM, but a SIGKILL cannot be
trapped: when the command ignores SIGTERM, the wrapper is killed while it is
still waiting, the command lives on as an orphan that launchd no longer knows
about, and the audit log holds a start line with no outcome. launchd's sweep of
the process group afterwards sends only one more SIGTERM (seen on macOS 27.0.1,
[#24](https://github.com/JJBalisan/launchd-run/issues/24)).

`--kill-after SECONDS` gives the wrapper a deadline of its own. If the command
is still running `SECONDS` seconds after the wrapper forwarded SIGTERM, the
wrapper sends it SIGKILL (never sooner, and about a second later at the most),
reaps it, logs

```text
stopped by signal, SIGKILL after 15s (exit 137, 86400s) - not counted
```

and exits 137. Like any other stop, this neither raises the counter nor clears
a streak. A command that exits before the deadline is left alone and logged as
an ordinary stop. Without the option nothing changes: the wrapper waits for the
command for as long as it takes.

```text
[ ~/.local/bin/launchd-run.sh, com.example.server, --kill-after, 15, --,
  ~/bin/server ]
```

goes with `<key>ExitTimeOut</key><integer>20</integer>` in the same plist.

- `SECONDS` is a positive integer of at most 9 digits; anything else is a
  usage error (exit 64) and the command is not run.
- It must be below the plist's `ExitTimeOut` by a few seconds: the SIGKILL can
  land a little over a second after `SECONDS` (the wrapper's clock ticks in
  whole seconds and it looks ten times a second), and the wrapper then needs a
  moment to reap the command and write its line. At or above `ExitTimeOut` the
  option does nothing, because launchd kills the wrapper first.
- Set `ExitTimeOut` in the plist rather than relying on the default, which
  `man launchd.plist` only calls "system-defined". The wrapper cannot read the
  plist, which is why it is told the number.
- The SIGKILL goes to the command's own pid, as the forwarded SIGTERM does.
  Processes the command started are not signalled
  ([#44](https://github.com/JJBalisan/launchd-run/issues/44)).
- The deadline starts when the wrapper first sees the stop, and is not
  restarted by later signals.

## Log rotation

The wrapper trims `~/Library/Logs/launchd-run.log` itself. Once the file passes
1 MB (about 15,000 lines, some two years at the usual rate) it keeps the last
5,000 lines: the trimmed copy is written beside the log and renamed over it, and
the trim is noted in the log. A line another job appends during that rename can
be lost, which is accepted for an audit trail of this kind. Nothing in
`/etc/newsyslog.d` is needed.

## Releasing

`install.sh` symlinks the wrapper into this checkout, so deploying is
`git pull` here and a release is just a name for what is deployed. The
version on each start line is `git describe --tags --long --dirty` of the
checkout (`lib/version.sh`): `v1.0.0-0-g<sha>` on a release, `v1.0.0-3-g<sha>`
three commits past it, `-dirty` appended while the tree has local edits,
`unknown` if the wrapper was copied out of the repo. `./install.sh` prints the
version it installs.

1. Move the `[Unreleased]` entries in `CHANGELOG.md` under a new
   `[X.Y.Z] - date` heading and update the compare links at the bottom.
2. Merge to `main`, pull, then tag the merge commit and push the tag over
   SSH (the https remote pushes only through the gh credential helper):

   ```bash
   git tag -a vX.Y.Z -m vX.Y.Z \
     && git push git@github.com:JJBalisan/launchd-run.git vX.Y.Z
   ```

3. The next run of any wrapped job starts with
   `started: launchd-run vX.Y.Z-0-g<sha>` in the audit log.

MAJOR when the wrapper changes what it counts, when it alerts or where it
writes, MINOR for a new flag or behaviour, PATCH for a fix.

## Why a wrapper rather than a line in each script

The jobs it guards are written in different languages and live in different
places — a git clone, a cloud mount, another repo. Wrapping at the plist level
guards all of them without editing a single working script, and it catches
non-zero exits uniformly.

Its blind spot is the job that exits 0 having done nothing. No wrapper can see
that; the job itself has to notice. Two jobs in
[launchd-jobs](https://github.com/JJBalisan/launchd-jobs) do:
`miniflux-healthcheck` fails when no feed has been polled for 3 h even though
the health endpoint answers, and `spicetify-autoupgrade` compares the
`spicetify` on PATH with the version Homebrew installed, so a shadowed binary
is not taken for an up-to-date one.

## Do not wrap a job that drives the GUI

macOS attributes Automation permission (`tell application "System Events" …`) to
the process launchd started. Inserting this wrapper changes that process from,
say, `python3` to `bash`, so the existing grant no longer applies and the job
blocks on a permission prompt that a background agent cannot show. A
wallpaper-setting job here hung exactly this way.

`display notification` is a *different* permission class and is unaffected —
this wrapper's own banners work fine from the same bash context.
