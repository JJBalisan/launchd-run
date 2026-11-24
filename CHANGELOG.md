# Changelog

Every release is an annotated git tag `vX.Y.Z` on `main`; see "Releasing" in
the README. The wrapper logs the tag or commit it runs from on the start line
of every run (`started: launchd-run <version>` in
`~/Library/Logs/launchd-run.log`), so an audit line can always be matched to
an entry here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions: [Semantic Versioning](https://semver.org/spec/v2.0.0.html), where
a MAJOR change alters what the wrapper counts, when it alerts or where it
writes, MINOR adds a flag or a behaviour, PATCH fixes one.

## [Unreleased]

## [3.0.1] - 2026-11-24

### Fixed

- A missing `~/Library/Logs` is created, and an audit log that cannot be
  written gives one warning line instead of bash errors on the job's
  stderr (#58).

### Changed

- The README describes the remaining hang or crash inside bash 3.2's
  `wait` when a stop arrives just after the job dies of a signal (#52).
- Tests only: no fixed sleep before signalling the wrapper, one helper
  for the wrapper's environment, less duplication, and the suite removes
  only the macOS crash reports it caused (#32, #39, #40, #53).

## [3.0.0] - 2026-11-24

### Added

- `--kill-after SECONDS`, an opt-in kill deadline for a job that ignores
  SIGTERM. launchd's SIGKILL after `ExitTimeOut` hits the wrapper alone, which
  left such a job running as an orphan with no outcome line (#24). With the
  option, a job still running `SECONDS` seconds after the wrapper forwarded
  SIGTERM is sent SIGKILL by the wrapper (never sooner, about a second later
  at the most), reaped and logged as
  `stopped by signal, SIGKILL after Ns (exit 137, ...) - not counted`. Set it
  a few seconds below the plist's `ExitTimeOut`. `SECONDS` is a positive
  integer of at most 9 digits. Without the option nothing changes.

### Changed

- An unremovable fail count is now reset to 0 on success, so the recovery
  is reported once with the "Back to normal" banner where it was silently
  skipped before (#48). This changes when the wrapper alerts, hence MAJOR.
- The command is exec'd with the caller's environment and looked up on
  `PATH`, so a shell builtin (`-- eval ...`, `-- :`) no longer works as the
  command (#27, #30).
- USR1, USR2 and ALRM are passed on to the command; PIPE and QUIT no longer
  end the wrapper (#37).
- Without `HOME` the command runs directly with a warning and no
  bookkeeping, instead of the wrapper aborting (#26).
- The audit log is trimmed once past 16 MB, to its last 100,000 lines (was
  1 MB and 5,000) (#36).
- The README now says what `alert sent` means (#31), what happens to a
  command's children on a stop (#44), that macOS 12.3 or later is required
  (#47), and what `kill 0` in a job does to the wrapper (#38).

### Fixed

- A stop before the job is forked, or just after, is no longer lost or
  fatal; one small window inside bash 3.2's `wait` remains and is
  described in the README (#27).
- Repeated stops no longer end the wrapper before the job has gone (#25).
- A caller's variable named like one of the wrapper's reaches the job
  unchanged (#23).
- A command named like a wrapper function runs the program on `PATH`
  (#30).
- `--after` takes at most 9 digits; a longer stored fail count restarts
  the streak (#45).
- A label with `/` or a leading `.` is a usage error (#46).

## [2.0.0] - 2026-11-20

### Changed

- A run counts as a stop only when the wrapper itself was signalled (SIGHUP,
  SIGINT, SIGTERM), not by the job's exit code. A job that dies of SIGKILL or
  SIGTERM (137, 143) while the wrapper was not signalled, or exits with any
  other signal code in 129..143, now counts as a failure and raises the
  failure banner after `--after` runs, where it was silently ignored before
  (#21, #22, #49). This changes what the wrapper counts, hence MAJOR.

### Fixed

- A job that dies of a crash signal (SIGSEGV, SIGABRT, SIGBUS, ...) now
  takes the wrapper down with the same signal instead of an `exit 139`, so
  launchd sees a crash and `KeepAlive = { Crashed = true; }` restarts it.
  bash's own "Segmentation fault" report no longer lands on the job's stderr.
- A failure count that cannot be saved (a root-owned or non-directory
  `~/.local/state`) no longer leaves the streak stuck at 1 with no alert:
  every failure then raises a banner and the audit line says why.
- A failure count that cannot be cleared (it sits in a directory the wrapper
  cannot write to) no longer raises a false "Back to normal" banner, with
  `rm: Permission denied` on the job's stderr, on every success. The audit
  line says the counter cannot be cleared.

## [1.0.4] - 2026-11-02

### Changed

- The pre-commit shellcheck hook passes `-x`, as dev-toolchain's template
  does, so a staged script whose sourced file is not staged no longer fails
  SC1091 (dev-toolchain#43).

## [1.0.3] - 2026-10-29

### Added

- MIT licence (`LICENSE`); the repository is now public.

## [1.0.2] - 2026-10-29

### Changed

- CI follows dev-toolchain's template: push runs on `main` only and a
  newer push to a PR cancels its older run, so a PR runs once;
  `actions/checkout` v7.
- `lib/version.sh` refreshed from dev-toolchain's template.

## [1.0.1] - 2026-10-28

### Changed

- README: the "blind spot" pointer named the `spicetify-autoupgrade` repo,
  archived on 27 Oct 2026; it now names that job and `miniflux-healthcheck`
  in launchd-jobs (#11).

## [1.0.0] - 2026-10-26

First tagged release: the wrapper as it stands after the 25 October 2026
audit fixes (#8) and the single-script CI (#9).

### Added

- `launchd-run.sh LABEL [--after N] -- command...` runs the command with
  stdout, stderr and the exit code passed straight through, keeps a
  per-label consecutive-failure counter in
  `~/.local/state/launchd-run/<label>/`, and raises a Notification Center
  banner once the job has failed N times in a row (default 2), again every
  run it stays broken and once more on recovery. A counter file that does
  not hold a plain decimal reads as 0 and restarts the streak.
- Exit codes 129, 130, 137 and 143 (a stop by signal) are recorded as
  `stopped by signal` and ignored: they neither raise the counter nor clear
  a streak. Crash signals 134, 138 and 139 count.
- SIGHUP, SIGINT and SIGTERM sent to the wrapper are forwarded to the
  command as SIGTERM; the wrapper waits for it and then logs the stop, so a
  `launchctl kickstart -k` leaves one audit line and no orphan (#8).
- `--after` must be a positive integer and the command must follow `--`;
  anything else is a usage error (exit 64) and the command is not run (#8).
- Banner text, title and subtitle reach osascript as argv, never spliced
  into the AppleScript source (#8).
- The audit log is trimmed to its last 5,000 lines once it passes 1 MB, the
  trim noted in the log (#8).
- Every run writes a start line, `started: launchd-run <version>`, where
  the version is `git describe --tags --long --dirty` of the checkout the
  installed symlink resolves to (`lib/version.sh`), `unknown` outside a
  repository. `install.sh` prints the version it installs.
- `tests/run.sh`: hermetic suite (temporary HOME, stub osascript, version
  pinned to `vTEST`) run under both the PATH bash and `/bin/bash` 3.2;
  `tests/version.sh` for the lib; `tests/ci.sh` is the whole CI as one
  script and the workflow's only step (#9), linting every tracked `.sh`.

[Unreleased]: https://github.com/JJBalisan/launchd-run/compare/v3.0.1...HEAD
[3.0.1]: https://github.com/JJBalisan/launchd-run/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/JJBalisan/launchd-run/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/JJBalisan/launchd-run/compare/v1.0.4...v2.0.0
[1.0.4]: https://github.com/JJBalisan/launchd-run/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/JJBalisan/launchd-run/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/JJBalisan/launchd-run/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/JJBalisan/launchd-run/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/JJBalisan/launchd-run/releases/tag/v1.0.0
