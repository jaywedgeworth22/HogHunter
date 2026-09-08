#!/bin/bash
# Build Hog Hunter Release, sign it, and install it to ~/Applications.
#
# Usage: scripts/install.sh [--adhoc] [--no-launch] [--dry-run]
#   --adhoc      Skip Developer ID signing even if the identity is available.
#   --no-launch  Install but do not open Hog Hunter afterward.
#   --dry-run    Build only.  Print what would happen next.  Never sign,
#                quit the running app, copy to ~/Applications, or launch.
set -euo pipefail

ADHOC=0
NO_LAUNCH=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --adhoc) ADHOC=1 ;;
    --no-launch) NO_LAUNCH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--adhoc] [--no-launch] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_PATH="build/Build/Products/Release/HogHunter.app"
INSTALLED_PATH="$HOME/Applications/HogHunter.app"

version_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo "unknown"
}

echo "Generating the Xcode project."
xcodegen generate

echo "Building Release."
xcodebuild -scheme HogHunter -configuration Release -derivedDataPath build \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce $APP_PATH." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: built $APP_PATH."
  echo "Would sign it, quit the running Hog Hunter, install to $INSTALLED_PATH, and launch it.  Doing none of that."
  echo "Hog Hunter $(version_of "$APP_PATH") (dry run, not installed)."
  exit 0
fi

sign_adhoc() {
  local reason="$1"
  echo "Signing adhoc ($reason)."
  codesign --force --deep --sign - "$APP_PATH"
}

DEVELOPER_ID_AVAILABLE=0
if [[ "$ADHOC" -eq 1 ]]; then
  : # --adhoc requested; skip the Developer ID check entirely.
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  DEVELOPER_ID_AVAILABLE=1
fi

if [[ "$DEVELOPER_ID_AVAILABLE" -eq 1 ]]; then
  echo "Signing with Developer ID Application.  20 second timeout."
  # macOS has no `timeout` binary, so bound codesign with perl's alarm instead.
  if perl -e 'alarm 20; exec @ARGV or exit 1' codesign --force --deep --options runtime --timestamp=none \
      --sign "Developer ID Application" "$APP_PATH"; then
    echo "Signed with Developer ID Application."
  else
    sign_adhoc "Developer ID signing failed or timed out"
  fi
elif [[ "$ADHOC" -eq 1 ]]; then
  sign_adhoc "--adhoc requested"
else
  sign_adhoc "no Developer ID Application identity in keychain"
fi

echo "Verifying the signature."
codesign --verify --deep --strict "$APP_PATH"
echo "Entitlements (get-task-allow should be absent):"
codesign -d --entitlements - "$APP_PATH"

echo "Quitting the running Hog Hunter, if any."
osascript -e 'tell application "HogHunter" to quit' >/dev/null 2>&1 || true
sleep 5
if pgrep -x HogHunter >/dev/null 2>&1; then
  echo "Hog Hunter is still running.  Forcing it to quit."
  pkill -x HogHunter || true
fi

echo "Installing to $INSTALLED_PATH."
mkdir -p "$HOME/Applications"
ditto "$APP_PATH" "$INSTALLED_PATH"

if [[ "$NO_LAUNCH" -eq 0 ]]; then
  echo "Launching Hog Hunter."
  open "$INSTALLED_PATH"
else
  echo "Skipping launch (--no-launch)."
fi

echo "Installed Hog Hunter $(version_of "$INSTALLED_PATH")."
