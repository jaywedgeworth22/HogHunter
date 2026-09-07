# Hog Hunter

A Mac menu bar utility that names the processes and apps eating CPU and memory right now, over the past hour, and over the past 24 hours.  Quit a hog from the list after a confirm.

Local only.  Not on the App Store.  Not TestFlight.

## What it shows

- Menu bar: live machine CPU percent.
- Panel meters: CPU and memory.
- **Now** — live snapshot.  100% CPU is one core fully busy (same idea as Activity Monitor).
- **Past Hour** / **Past 24 Hours** — averages from samples Hog Hunter took while it was open.
- **Apps** groups helpers (Chrome, Electron, …) under one row.  **Processes** lists pids.
- **Quit** / **Force Quit** on live rows.  History rows are look-only.

History only covers time the menu bar app has been running.  Turn on **Launch at Login** if you want a real day of data.

## Build and run

```bash
cd ~/apps/HogHunter
xcodegen generate
xcodebuild -scheme HogHunter -configuration Release -derivedDataPath build
open build/Build/Products/Release/HogHunter.app
```

No LaunchAgent.  The app is the sampler.  Quitting it stops history.

## Notes

Light appearance is the default.  Headings and buttons are Title Case.  Body copy is sentence case with two spaces between sentences.
