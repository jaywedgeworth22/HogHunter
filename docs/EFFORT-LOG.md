# Hog Hunter — effort log

Mirror of the live fleet board rows for this app.  Reserve a row before starting work.  Never delete another seat's rows.

| Date (CT) | Seat | Branch | State | Work |
|---|---|---|---|---|
| Mon, Sep 8, 2026 | GROK | grok/cpu-mach-timebase | Landed (#1) | Convert mach ticks with timebase before per-process CPU% |
| Mon, Sep 8, 2026 | CLAUDE | claude/hog-hunter-overhaul | In progress | Owner-directed takeover after the audit: pid identity and wrap guard, footprint memory, history math, swap and pressure, visible-vs-invisible accounting, safer quit, grouping identity, settings, tests, CI, install script.  Design: docs/DESIGN.md |
| Mon, Sep 8, 2026 | CLAUDE | claude/hog-hunter-ci | Landed (#2) | Test target, GitHub Actions CI on macOS, hardened Release without get-task-allow, scripts/install.sh with Developer ID signing and adhoc fallback |
