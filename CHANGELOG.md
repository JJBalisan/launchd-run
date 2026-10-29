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

[Unreleased]: https://github.com/JJBalisan/launchd-run/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/JJBalisan/launchd-run/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/JJBalisan/launchd-run/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/JJBalisan/launchd-run/releases/tag/v1.0.0
