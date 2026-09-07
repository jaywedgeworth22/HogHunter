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

No LaunchAgent.  The running menu bar app is the sampler.  History only covers time it has been open.

## Copy

Light default.  Title Case chrome.  Body sentence case with two ASCII spaces.
