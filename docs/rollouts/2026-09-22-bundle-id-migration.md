# 2026-09-22 — Bundle Identifier Migration

Issue raised on the macOS signing-cert change window, where the owner approved a fleet-wide bundle rename so every app uses a domain Jay owns as its base.  This document covers **HogHunter only**; the rest of the fleet (BotFleet, Autorotate, ContactLogo, Socratic.Trade, Congress.Trade, Usage-Monitor, MiniMax-ios) is on separate lanes owned by other seats.  The fleet-wide context lives in `/Users/jay/.minimax/sessions/mvs_0bdfe8c73c1046a986df888aa99dcb2e/workspace/fleet-bundle-id-plan.md`.

HogHunter is the smallest lane in the fleet (single macOS target, no iOS shell, no web refs, no LaunchAgent).  Two renames (app + tests), one new App Group, one new Associated Domain, no code-signing identity beyond the existing "Developer ID Application" / adhoc fallback that `scripts/install.sh` already handles.

## Previous → New

| Surface | Previous | New |
|---|---|---|
| macOS app (`HogHunter`) | `com.jayservices.HogHunter` | `com.simplewithus.hoghunter.macos` |
| macOS unit tests (`HogHunterTests`) | `com.jayservices.HogHunterTests` | `com.simplewithus.hoghunter.macos.tests` |
| App Group (new) | — | `group.com.simplewithus.hoghunter` |
| Associated Domain (new, macOS only) | — | `simplewithus.com` |
| Associated Domain values (new, macOS only) | — | `applinks:simplewithus.com`, `webcredentials:simplewithus.com` |
| `bundleIdPrefix` (XcodeGen base) | `com.jayservices` | `com.simplewithus.hoghunter` |
| `Library/Application Support/HogHunter/` | `HogHunter` | `HogHunter` (keep — internal storage path, not a bundle ID) |
| `~/Library/Logs/HogHunter/` | `HogHunter` | `HogHunter` (keep — internal logs path, not a bundle ID) |
| `osascript` / `pgrep -x` display name `"HogHunter"` | `HogHunter` | `HogHunter` (keep — process display name, not a bundle ID) |

The three "keep" rows are **intentionally** out of scope: they are user-visible paths and the running-process name, not bundle IDs.  Renaming them would orphan existing user history and break the running-app quit path on every installed copy.  This is the same call the BotFleet, Autorotate, and ContactLogo workers made for analogous internal namespaces.

## What changed in the repo

- `project.yml`:
  - Top-of-file dated callout pointing to this rollout doc.
  - `options.bundleIdPrefix`: `com.jayservices` → `com.simplewithus.hoghunter` (XcodeGen base for any future derived IDs; both targets below set `PRODUCT_BUNDLE_IDENTIFIER` explicitly so this is cosmetic today but keeps the base consistent).
  - `HogHunter` app target `PRODUCT_BUNDLE_IDENTIFIER`: `com.jayservices.HogHunter` → `com.simplewithus.hoghunter.macos`.
  - `HogHunterTests` target `PRODUCT_BUNDLE_IDENTIFIER`: `com.jayservices.HogHunterTests` → `com.simplewithus.hoghunter.macos.tests`.
  - `CODE_SIGN_ENTITLEMENTS: HogHunter.entitlements` placement unchanged (Release config only — matches the prior ContactLogo rollout pattern; Debug builds do not need the App Group / Associated Domain entitlement today).
- `HogHunter.entitlements`:
  - Was an empty `<dict>`; now carries:
    - `com.apple.security.application-groups: [group.com.simplewithus.hoghunter]` (App Group).
    - `com.apple.developer.associated-domains: [applinks:simplewithus.com, webcredentials:simplewithus.com]` (Universal Links + shared Safari webcredentials on `simplewithus.com`, which Jay owns and which resolves).
  - File header comment explains the rationale + the owner-action prerequisites (App Group must be registered per App ID in the Apple Developer Portal; AASA must be hosted at `https://simplewithus.com/.well-known/apple-app-site-association`).
- `AGENTS.md`:
  - Top-of-file dated callout pointing to this rollout doc; flags the internal-namespace decision (Log/Storage/osascript display name `HogHunter` are NOT renamed).
  - New canonical `## Bundle identifiers` table listing the macOS app + tests targets + the App Group + Associated Domain + a pointer to this rollout doc.
  - New `## Internal namespaces (NOT bundle IDs — do not rename)` section documenting the three `Sources/*` references that survived the rename on purpose.
- `docs/EFFORT-LOG.md`:
  - New `Tue, Sep 22, 2026 | MM | minimax/bundle-rename | Landed (#PR)` row at the top of the table describing this rollout, with branch + worktree + board + owner actions.
  - All pre-rename rows left in place (no archaeology note required — the table never named bundle IDs in the `Work` column, only seat/branch/work summaries).

### Out-of-scope files (not edited, intentionally)

- `Sources/History/HistoryStore.swift:83` — `Library/Application Support/HogHunter/` (history SQLite + samples directory).  Internal path; renaming would orphan user data.
- `Sources/Store/ProcessControl.swift:22` — `"HogHunter"` display name used by `osascript -e 'tell application "HogHunter" to quit'` and `pgrep -x HogHunter`.  Process display name; renaming would break the running-app quit path on every installed copy.
- `Sources/UI/RowView.swift:156` — `~/Library/Logs/HogHunter/` (Sample-for-3-Seconds report target).  Internal path; renaming would orphan user logs.
- `docs/DESIGN.md` — references `HogHunter.entitlements` as "empty" with Release hardened runtime.  The "empty" wording is now stale (entitlements carries the App Group + Associated Domain), but the design doc captures the original 1.1 hardened-runtime intent and is intentionally left as a historical record.  Future design doc revisions will note the addition.
- `README.md`, `CHANGELOG.md`, `scripts/install.sh`, `.github/workflows/ci.yml` — none reference the bundle ID.  `install.sh` already handles "Developer ID Application" / adhoc fallback and uses the `HogHunter.app` directory name (unchanged).
- `Sources/Models.swift` and all other `Sources/**` Swift files — grep confirmed zero references to `com.jayservices` or any bundle-ID string.  `Bundle.main` is not introspected for the bundle ID anywhere.
- `Tests/HogHunterTests/**` — pure-Swift unit tests, no `Bundle.main` / Info.plist / bundle-ID introspection.  No edits.
- No `dealdex.net`, `services.jays.*`, `com.botfleet.*`, `codes.autorotate.*`, `com.contactlogo.*`, `trade.socratic.*`, `trade.congress.*`, `net.dealdex`, `app.botfleet.*`, or `codes.autorotate.*` references exist in this repo.  No web refs to update.

## Cross-repo files touched (not in this PR's diff)

- `~/Library/LaunchAgents/` — none (HogHunter has no LaunchAgent or helper process; the running menu bar app is the sampler).
- `~/apps/hoghunter-*-start.sh` / `~/apps/hoghunter-*.py` — none of these exist; HogHunter has no agent harness.
- `/Users/jay/Code/HogHunter/` — the human integration tree.  No edits; the worktree stays on `minimax/bundle-rename` and the owner merges through the PR.

## Owner action items

1. **Apple Developer Portal** — register the new explicit App IDs: `com.simplewithus.hoghunter.macos` (app) and `com.simplewithus.hoghunter.macos.tests` (test bundle).  Add the App Group capability `group.com.simplewithus.hoghunter` on **both** App IDs (it must be registered per-App-ID for `UserDefaults` sharing + shared-container participation).  Add the Associated Domain capability `simplewithus.com` (`applinks` + `webcredentials`) on `com.simplewithus.hoghunter.macos`.  This PR does not have the credentials to do so.
2. **`simplewithus.com` DNS + AASA** — host the Apple App Site Association at `https://simplewithus.com/.well-known/apple-app-site-association` on the verified `simplewithus.com` zone (Universal Links for `com.simplewithus.hoghunter.macos` and webcredentials for any future shared Safari password flow).  The associated-domains entitlement values `applinks:simplewithus.com` and `webcredentials:simplewithus.com` are already wired in `HogHunter.entitlements`; they will validate once the AASA is reachable.
3. **Code-signing** — the certificate refresh is vendor-driven and out of scope.  After the cert swap, the build picks up the new bundle ID without any further source change (`project.yml` flows the new `PRODUCT_BUNDLE_IDENTIFIER` into `HogHunter.xcodeproj` via `xcodegen generate`, and `scripts/install.sh` continues to sign with "Developer ID Application" when present in the keychain, falling back to adhoc otherwise).
4. **Auto-update / re-install** — `scripts/install.sh --dest /Applications` (or `--dest ~/Applications`) is the install path; the next install after the portal update will register the new bundle ID on the user's machine.  HogHunter does not use TestFlight (per `AGENTS.md`: "**Do not** App Store or TestFlight unless the owner asks").
5. **No data migration needed** — user history lives under `~/Library/Application Support/HogHunter/` and `~/Library/Logs/HogHunter/`; both survive the bundle-ID rename unchanged because the paths are independent of the bundle ID.

## Verification

- `git grep -nE 'com\.jayservices'` returns only one archaeology hit: `project.yml:3` — the top-of-file dated callout that records the old ID for historical context.  No other `com.jayservices` reference exists in the active tree.
- `git grep -nE 'com\.jayservices\.HogHunter'` returns one archaeology hit (the same `project.yml:3` callout) and nothing else.
- `git grep -nE 'com\.simplewithus\.hoghunter'` returns: `project.yml` (`bundleIdPrefix`, both `PRODUCT_BUNDLE_IDENTIFIER` values, dated callout), `HogHunter.entitlements` (both keys + header comment), `AGENTS.md` (callout + Bundle identifiers table + Internal namespaces section), `docs/EFFORT-LOG.md` (new top row), `docs/rollouts/2026-09-22-bundle-id-migration.md` (this file).
- `git grep -nE 'HogHunter'` (case-sensitive, to catch any remaining bundle-shaped references) returns: `project.yml` (`PRODUCT_NAME: HogHunter`, scheme name), `Sources/**` (the three intentionally-preserved internal-namespace references documented above), `scripts/install.sh` (the `HogHunter.app` install target + `osascript`/`pgrep -x` calls), `Tests/**` (target directory name only), `AGENTS.md` / `README.md` / `CHANGELOG.md` / `docs/DESIGN.md` / `docs/EFFORT-LOG.md` (prose + headings).  All non-prose hits are either process/path names (not bundle IDs) or prose.
- `plutil -lint HogHunter.entitlements` — clean.
- `xcodegen generate` regenerates `HogHunter.xcodeproj` from `project.yml`; the new `PRODUCT_BUNDLE_IDENTIFIER` values flow into both targets' Debug + Release build settings without any hand edit.
- `xcodebuild -list -project HogHunter.xcodeproj` (post-`xcodegen generate`) lists both targets (`HogHunter` + `HogHunterTests`) cleanly with both Debug + Release build configurations and the `HogHunter` scheme.
- `HogHunter.entitlements` carries `com.apple.security.application-groups: [group.com.simplewithus.hoghunter]` and `com.apple.developer.associated-domains: [applinks:simplewithus.com, webcredentials:simplewithus.com]`.
- `AGENTS.md` Bundle Identifiers section is the new canonical table for future seats; top-of-file callout points to this rollout doc.
- `docs/EFFORT-LOG.md` carries the new `Tue, Sep 22, 2026 | MM | minimax/bundle-rename | Landed (#PR)` row at the top of the table; pre-rename rows are preserved as history (none referenced the bundle ID in prose).
- `Sources/History/HistoryStore.swift:83`, `Sources/Store/ProcessControl.swift:22`, `Sources/UI/RowView.swift:156` references to `"HogHunter"` were searched but **not** edited — they are internal paths/process names, not bundle IDs.

## Out of scope

- Apple Developer Portal App ID + App Group + Associated Domain registration (owner).
- `simplewithus.com` AASA hosting + DNS (owner).
- Code-signing cert refresh (vendor).
- Auto-update / re-install (no source change required; the install script picks up the new bundle ID via `xcodegen generate` → `xcodebuild`).
- Keychain service strings (HogHunter does not currently use a named Keychain service group; if one is added later, it will use the `simplewithus.hoghunter` namespace).
- Internal path/process namespaces (`Library/Application Support/HogHunter/`, `~/Library/Logs/HogHunter/`, the `osascript`/`pgrep -x` display name) — not bundle IDs.
- Renaming the design-doc phrasing "empty entitlements" in `docs/DESIGN.md` — the design doc captures the original 1.1 hardened-runtime intent and is intentionally left as a historical record.
- Other fleet apps' bundle renames (separate per-app PRs, separate seats).