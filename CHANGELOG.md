# Changelog

## Unreleased

Infrastructure additions (build, test, and release plumbing; no app behavior changed):

- Added a `HogHunterTests` XCTest target (`Tests/HogHunterTests/`) and a `HogHunter` scheme that builds and runs it, starting with coverage for `HogFormat.cpu` and `HogFormat.memory`.
- Added `HogHunter.entitlements` (empty) and turned on `ENABLE_HARDENED_RUNTIME` for Release builds, with `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` so Release binaries carry no `get-task-allow` entitlement.
- Added `.github/workflows/ci.yml`: runs `xcodegen generate` and `xcodebuild test` on macOS for every push to `main` and every pull request.
- Added `scripts/install.sh`: builds Release, signs with the "Developer ID Application" identity when available (adhoc fallback otherwise), verifies the signature, quits and replaces the running install in `~/Applications`, and relaunches.  Supports `--adhoc`, `--no-launch`, and `--dry-run`.
- Updated `build.sh`, `README.md`, and `AGENTS.md` to point at `scripts/install.sh` and the new test target and CI.
