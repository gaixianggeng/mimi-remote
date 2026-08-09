#!/usr/bin/env bash
#
# STALE — this does not refresh what the site currently ships.
# The assets in web/assets are real-device captures named
#     {ipad,iphone}-{workspace,sessions}-{light,dark}.png
# and the site picks between them by appearance, not by language. This script
# still produces the older seeded, language-suffixed set, so running it will
# write files the page no longer loads (and will not update the ones it does).
# Rewrite it against the naming above before using it again.
#
# Capture the language-matched product screenshots the marketing site needs.
#
# Why this exists: the site shows iPad + iPhone, and swaps the screenshot to
# match the EN / 中文 toggle. We already ship two of the four sets:
#     ipad-*-en.png       (English iPad)      ✓ real
#     iphone-*-zh.png     (Chinese iPhone)    ✓ real
# The other two are placeholders (copied from the opposite language) until you
# run this on a machine where the iOS Simulator works. Codex's sandbox blocks
# CoreSimulator, so this could not be run from the agent session.
#
# Run from the repo root or from web/:
#     ./web/capture-screenshots.sh
#
# It builds the Debug app once, then for each (device, language) boots the sim,
# launches with the debug seed flags, captures the workspace screen
# automatically, and pauses for you to open the seeded "Connection recovery"
# conversation before capturing it. Output lands directly in web/assets/.
#
set -euo pipefail

# --- config: match the devices the existing shots were taken on -------------
IPAD_SIM="${IPAD_SIM:-iPad Pro 13-inch (M5)}"    # -> 2064 x 2752
IPHONE_SIM="${IPHONE_SIM:-iPhone 17 Pro}"        # -> 1206 x 2622
SCHEME="${SCHEME:-MimiRemote}"
BUNDLE_ID="${BUNDLE_ID:-}"                        # auto-detected if empty

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ_DIR="$ROOT/ios/MimiRemote"
OUT="$ROOT/web/assets"
DERIVED="$PROJ_DIR/build/screenshots-derived"

cd "$PROJ_DIR"

echo "==> Building Debug app for simulator (once)…"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED" \
  build | tail -3

APP="$(find "$DERIVED/Build/Products" -name 'MimiRemote.app' -path '*imulator*' | head -1)"
[ -n "$APP" ] || { echo "!! Could not find built MimiRemote.app"; exit 1; }
if [ -z "$BUNDLE_ID" ]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
fi
echo "==> App:  $APP"
echo "==> Bundle: $BUNDLE_ID"

shoot () {  # device  lang  seedflag  outfile
  local device="$1" lang="$2" seed="$3" out="$4"
  echo
  echo "==> [$device / $lang] launching ($seed)…"
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b >/dev/null 2>&1 || true
  xcrun simctl install "$device" "$APP"
  xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$device" "$BUNDLE_ID" \
    --debug-skip-pairing "$seed" -app.language "$lang" >/dev/null
  sleep 4
  xcrun simctl io "$device" screenshot "$out"
  echo "    saved $out"
}

# helper to fully script the workspace shot, and pause for the conversation shot
capture_device () {  # device  lang(en|zh-Hans)  suffix(en|zh)
  local device="$1" lang="$2" sfx="$3"
  local kind="iphone"; case "$device" in *iPad*) kind="ipad";; esac

  shoot "$device" "$lang" "--debug-seed-ui"       "$OUT/${kind}-workspace-${sfx}.png"

  shoot "$device" "$lang" "--debug-seed-queue-ui" "$OUT/${kind}-conversation-${sfx}.png.raw"
  echo
  echo "    >> In the simulator, open the seeded 'Connection recovery' conversation,"
  echo "       then press Enter here to capture it."
  read -r _
  xcrun simctl io "$device" screenshot "$OUT/${kind}-conversation-${sfx}.png"
  rm -f "$OUT/${kind}-conversation-${sfx}.png.raw"
  echo "    saved $OUT/${kind}-conversation-${sfx}.png"

  xcrun simctl shutdown "$device" 2>/dev/null || true
}

# Only the two MISSING sets are needed. Uncomment the others to refresh all four.
echo "==> Capturing missing set 1/2: iPad 中文"
capture_device "$IPAD_SIM"   "zh-Hans" "zh"
echo "==> Capturing missing set 2/2: iPhone English"
capture_device "$IPHONE_SIM" "en"      "en"

# capture_device "$IPAD_SIM"   "en"      "en"   # refresh English iPad
# capture_device "$IPHONE_SIM" "zh-Hans" "zh"   # refresh Chinese iPhone

echo
echo "==> Done. Verify web/assets/{ipad,iphone}-{workspace,conversation}-{en,zh}.png,"
echo "    then reload the site — no code changes needed."
