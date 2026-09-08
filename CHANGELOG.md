# Changelog

## Unreleased

Sampling and data layer:

- Fixed per-process CPU: `proc_taskinfo` and `proc_pid_rusage` ticks are mach absolute-time units and are now converted with `mach_timebase_info`, so a row matches Activity Monitor instead of reading 41.7x too small.
- Per-process memory is now `ri_phys_footprint`, Activity Monitor's Memory column, with resident size kept for detail only.  Machine memory used follows Activity Monitor's formula, and App Memory, Wired, Compressed and Cached Files are all read.
- Added swap used and swap in/out rates, memory pressure from `kern.memorystatus_vm_pressure_level` with an immediate `DispatchSource` reaction, and thermal state.
- Processes are keyed by `ProcessKey(pid, startTime)`, so a recycled pid starts a fresh baseline instead of inheriting the old process's counters.
- Grouping walks `ppid` to the nearest regular app, then falls back to bundle id and executable path.  Two unrelated `node` processes no longer merge.
- Quitting re-checks identity, ownership and a denylist of processes that keep the desktop alive at the moment of the click, and reports what it skipped.
- History moved to a v2 SQLite schema with WAL: values are summed per timestamp before being divided by the window's tick count, results are memoized, every `sqlite3` return code is checked, and rows older than 24 h are pruned.
- Sampling runs on a utility queue.  LaunchServices work happens only for rows about to be drawn, and a tick that fires while the previous one is still running is skipped.

User interface:

- Added a Settings window (General, Appearance, Alerts, Launch at Login, About), reachable from a new gear menu in the panel header.
- Added CPU alerts: an optional notification when one app stays above a per-core threshold for a chosen number of minutes, with a 30 minute cooldown per app.  Off by default.
- Added an Appearance setting.  Light stays the default; System and Dark are available.
- Meters are tinted by severity, and swap, memory pressure and thermal state now appear as small pills under the memory meter.
- Rows gained a context menu: Copy PID, Reveal in Finder, Sample for 3 Seconds (writes to `~/Library/Logs/HogHunter/` and opens the report), and Open Activity Monitor.
- A row's CPU is colored only when it is elevated or hot, and a row that cannot be quit says why on hover instead of showing a dead button.
- The header staleness dot is now always visible: green when sampling is current, amber when it is behind.
- The Quit confirmation names the app, says how many processes are included, and says plainly what Force Quit will do.
- The menu bar can show the busiest app instead of machine CPU, with its name truncated to fit and help text naming the scale.

Infrastructure additions (build, test, and release plumbing; no app behavior changed):

- Added a `HogHunterTests` XCTest target (`Tests/HogHunterTests/`) and a `HogHunter` scheme that builds and runs it, starting with coverage for `HogFormat.cpu` and `HogFormat.memory`.
- Added `HogHunter.entitlements` (empty) and turned on `ENABLE_HARDENED_RUNTIME` for Release builds, with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` so Release binaries carry no `get-task-allow` entitlement.
- Added `.github/workflows/ci.yml`: runs `xcodegen generate` and `xcodebuild test` on macOS for every push to `main` and every pull request.
- Added `scripts/install.sh`: builds Release, signs with the "Developer ID Application" identity when available (adhoc fallback otherwise), verifies the signature, quits and replaces the running install in `~/Applications`, and relaunches.  Supports `--adhoc`, `--no-launch`, and `--dry-run`.
- Updated `build.sh`, `README.md`, and `AGENTS.md` to point at `scripts/install.sh` and the new test target and CI.
