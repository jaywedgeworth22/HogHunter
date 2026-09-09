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

Fixes from the 1.1 review:

- Alerts are now evaluated against every process or app above the threshold, not against the 25 rows the panel happens to be showing.  With Sort set to Memory, a CPU hog with a small footprint could previously never trigger a notification.
- The alert cooldown now expires by age instead of by visibility, so a row that drops off the list for a tick and comes back can no longer notify twice inside its 30 minute cooldown.
- Hog Hunter is now the notification centre's delegate, so a sustained-hog alert that fires while the panel or Settings is frontmost is shown instead of being silently dropped with its cooldown already spent.
- Notification authorization is settled at launch when alerts are already on, instead of being requested at the moment the first alert posts.
- The notification body names its scale: "Chrome has used 412% of one core for 5 minutes."
- Changing Window, Show or Sort no longer rebuilds rows inside SwiftUI's own view update, which drew "Publishing changes from within view updates is not allowed".
- The running-application table is now read once per pid instead of once per tick, cutting about 45 ms of main-thread work off every refresh, panel open or closed.
- History rows no longer re-run a file-system lookup for each row's display name on every refresh.
- The metadata cache is pruned every 60 ticks as documented, rather than every 1200.
- The history database is opened, migrated and first-pruned on the sampling queue instead of on the main actor during launch, so upgrading from the old schema no longer stalls the menu bar item for about half a second.
- A history failure now clears once queries work again, and no longer sits in the panel for the rest of the session.
- A failed history read is now reported instead of looking exactly like an empty window, and a `PRAGMA user_version` that cannot be read no longer counts as version 0, which would have dropped a healthy table.
- Errors are attributed to what caused them: the Launch at Login toggle shows only its own failure, a quit's summary is no longer red, and history failures have their own line.
- Two history ticks landing in the same second no longer double that second's CPU and memory, and the coverage note can no longer claim more sampled time than its own window holds.
- The menu bar item now reads the live number to VoiceOver instead of repeating the help text, and its help no longer names the per-core scale when the label has fallen back to machine CPU.
- Memory sizes just under a unit boundary print as "1.0 GB" and "1 MB" instead of "1024 MB" and "1024 KB".
- Memory-pressure transitions no longer add sampling passes on top of the timer; a pressure tick re-arms the timer instead, capping the rate at one pass per refresh interval.
- `stop()` now also cancels the memory-pressure source, `HogRow` equality compares every field except the icon, grouping no longer deep-copies a group's member list on every merge, and the `sample` child process no longer writes into a pipe nobody drains.
- Settings calls the login item "Launch at Login", the same name the panel and the coverage note use.

Infrastructure additions (build, test, and release plumbing; no app behavior changed):

- Added a `HogHunterTests` XCTest target (`Tests/HogHunterTests/`) and a `HogHunter` scheme that builds and runs it, covering `CpuMath` and `MemoryMath` conversion math, `Grouping`, `HistoryStore` aggregation, coverage, same-second ticks, error reporting and the v1-to-v2 migration, `AlertPolicy` sustain, cooldown and flapping behaviour, `MetadataResolver` caching, and `HogFormat` formatting.
- Added `HogHunter.entitlements` (empty) and turned on `ENABLE_HARDENED_RUNTIME` for Release builds, with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` so Release binaries carry no `get-task-allow` entitlement.
- Added `.github/workflows/ci.yml`: runs `xcodegen generate` and `xcodebuild test` on macOS for every push to `main` and every pull request.
- Added `scripts/install.sh`: builds Release, signs with the "Developer ID Application" identity when available (adhoc fallback otherwise), verifies the signature, quits and replaces the running install in `~/Applications`, and relaunches.  Supports `--adhoc`, `--no-launch`, and `--dry-run`.
- Updated `build.sh`, `README.md`, and `AGENTS.md` to point at `scripts/install.sh` and the new test target and CI.
