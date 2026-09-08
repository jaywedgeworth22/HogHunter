# Hog Hunter — agent notes

Mac menu bar utility.  Finds CPU and memory hogs now, over the past hour, and over the past 24 hours.  Quit from the list after confirm.

**Local:** `~/apps/HogHunter`  
**Installed app:** `~/Applications/HogHunter.app`  
**Do not** App Store or TestFlight unless the owner asks.

## Build

```bash
cd ~/apps/HogHunter
xcodegen generate
xcodebuild -scheme HogHunter -configuration Release -derivedDataPath build
ditto build/Build/Products/Release/HogHunter.app ~/Applications/HogHunter.app
```

Prefer `scripts/install.sh` over the manual steps above — it builds Release, signs with the "Developer ID Application" identity when it is in the keychain (adhoc otherwise), quits the running copy, installs to `~/Applications`, and relaunches.  Use `--dry-run` to check what it would do without touching the running app or `~/Applications`, or `--no-launch` to skip the relaunch.

`HogHunterTests` (XCTest, `Tests/HogHunterTests/`) covers pure logic such as `HogFormat`.  Run with `xcodebuild -scheme HogHunter -destination 'platform=macOS' test`.  CI (`.github/workflows/ci.yml`) runs the same on every push to `main` and every pull request.

No LaunchAgent.  The running menu bar app is the sampler.  History only covers time it has been open.

## Copy

Light default.  Title Case chrome.  Body sentence case with two ASCII spaces.
