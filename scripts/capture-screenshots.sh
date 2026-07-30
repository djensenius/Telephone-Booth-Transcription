#!/usr/bin/env bash
#
# capture-screenshots.sh — App Store screenshot capture for iOS and macOS.
#
# Builds the app, launches it in the bundled demo mode (login-free, deterministic
# DemoData) via the `-uiTestDemoMode` / `-uiScreenshotTab` launch arguments, and
# writes one PNG per tab into fastlane/screenshots/<platform>/en-CA/.
#
# Demo mode (see Sources/TranscriptionApp/DemoData.swift) swaps the live server
# for sample data: the server reads as "Running", the bearer token is revealed,
# and the request log is pre-populated, so no upstreams or network are required.
#
# Usage:  scripts/capture-screenshots.sh <iphone|ipad|ios|mac|all>
#
# Requirements:
#   * Xcode 26 + iOS 26 / macOS 26 SDKs.
#   * The Xcode project (regenerate with `xcodegen generate` if stale).
#   * For `mac`: grant Screen Recording permission to the controlling terminal
#     once (System Settings ▸ Privacy & Security ▸ Screen Recording).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Allow xcodebuild's SwiftPM resolution to read the cached bare package repos
# even when the user has `safe.bareRepository = explicit` set globally. Injected
# via env so we never mutate the user's git config.
export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-0}"
_idx="$GIT_CONFIG_COUNT"
export GIT_CONFIG_KEY_${_idx}="safe.bareRepository"
export GIT_CONFIG_VALUE_${_idx}="all"
export GIT_CONFIG_COUNT="$((_idx + 1))"

PROJECT="TelephoneBoothTranscription.xcodeproj"
APP_ID="org.davidjensenius.TelephoneBoothTranscription"
APP_OWNER="Transcriber" # CFBundleName, used to find the macOS window
DD="/tmp/tbt-dd"
SHOTS="$ROOT/fastlane/screenshots"
LOCALE="en-CA"
# iOS only has the two tabs; ContentView.iOSSelection folds the macOS-only
# `status` and `requests` values into Review, so asking for them there would
# just capture the same screen three times.
MAC_TABS=(review status settings requests)
IOS_TABS=(review settings)

log() { printf '\033[1;35m[shots]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[shots] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

udid_for() {
  xcrun simctl list devices available | grep -F "$1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

# Assert a PNG matches one of the accepted pixel sizes (space-separated "W H" pairs).
assert_size() {
  local file="$1"; shift
  local w h
  w=$(sips -g pixelWidth "$file" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$file" | awk '/pixelHeight/{print $2}')
  for pair in "$@"; do
    if [[ "$w $h" == "$pair" ]]; then log "  ✓ ${file##*/} = ${w}x${h}"; return 0; fi
  done
  die "${file##*/} is ${w}x${h}, expected one of: $*"
}

build_sim() {
  local scheme="$1" udid="$2"
  log "Building $scheme for simulator $udid …"
  xcodebuild -project "$PROJECT" -scheme "$scheme" \
    -destination "id=$udid" -configuration Debug \
    -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO >/tmp/tbt-build-"$scheme".log 2>&1 \
    || { tail -40 /tmp/tbt-build-"$scheme".log; die "build failed for $scheme"; }
}

# capture_sim <udid> <out_dir> <prefix> <sizes_csv>
capture_sim() {
  local udid="$1" out="$2" prefix="$3" sizes="$4"
  mkdir -p "$out"
  local app
  app=$(find "$DD/Build/Products" -maxdepth 2 -name '*.app' -path '*simulator*' | head -1)
  [[ -n "$app" ]] || die "no .app found in derived data"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$app"
  xcrun simctl status_bar "$udid" override --time "9:41" \
    --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true

  IFS=',' read -r -a sizearr <<< "$sizes"
  rm -f "$out/${prefix}_"*.png
  local i=1
  for tab in "${IOS_TABS[@]}"; do
    xcrun simctl terminate "$udid" "$APP_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$APP_ID" -uiTestDemoMode YES -uiScreenshotTab "$tab" >/dev/null
    sleep 6
    local f
    f=$(printf "%s/%s_%02d_%s.png" "$out" "$prefix" "$i" "$tab")
    xcrun simctl io "$udid" screenshot "$f" >/dev/null 2>&1
    assert_size "$f" "${sizearr[@]}"
    i=$((i + 1))
  done
}

do_iphone() {
  local u; u=$(udid_for "iPhone 17 Pro Max"); [[ -n "$u" ]] || die "iPhone 17 Pro Max sim not found"
  build_sim TranscriptionAppiOS "$u"
  capture_sim "$u" "$SHOTS/ios/$LOCALE" "iphone69" "1320 2868,1290 2796"
}

do_ipad() {
  local u; u=$(udid_for "iPad Pro 13-inch (M5)"); [[ -n "$u" ]] || die "iPad Pro 13 sim not found"
  build_sim TranscriptionAppiOS "$u"
  capture_sim "$u" "$SHOTS/ios/$LOCALE" "ipad13" "2064 2752,2048 2732"
}

# macOS: no simulator. Build, then run the .app once per tab and capture the
# window with `screencapture -l<windowid>`.
mac_window_id() {
  xcrun swift - "$APP_OWNER" <<'SWIFT' 2>/dev/null
import CoreGraphics
import Foundation
let owner = CommandLine.arguments.dropFirst().first ?? ""
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
  let o = (w[kCGWindowOwnerName as String] as? String) ?? ""
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  let h = (b["Height"] as? Double) ?? 0
  if o == owner && h > 400 {
    print((w[kCGWindowNumber as String] as? Int) ?? 0)
    break
  }
}
SWIFT
}

mac_kill() {
  local pids
  pids=$(ps -axo pid,command | grep "$PROJECT_APP_GLOB" | grep -v grep | awk '{print $1}' || true)
  for p in $pids; do kill "$p" 2>/dev/null || true; done
}

# Normalize a macOS window capture to an accepted App Store size. Apple requires
# one of a fixed set of 16:10 dimensions; a raw window grab is rarely an exact
# match. Center the window on a neutral canvas (downscaling only when the capture
# is larger than the canvas, so native pixels are preserved otherwise).
mac_normalize() {
  local f="$1" tw=2560 th=1600 bg=1c1c1e
  local w h
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}')
  if (( w > tw || h > th )); then
    sips --resampleHeightWidthMax "$tw" "$f" >/dev/null
    h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}')
    (( h > th )) && sips --resampleHeight "$th" "$f" >/dev/null
  fi
  sips --padToHeightWidth "$th" "$tw" --padColor "$bg" "$f" >/dev/null
}

do_mac() {
  log "Building TranscriptionApp for host …"
  xcodebuild -project "$PROJECT" -scheme TranscriptionApp \
    -configuration Debug -derivedDataPath "$DD" build \
    CODE_SIGNING_ALLOWED=NO >/tmp/tbt-build-mac.log 2>&1 \
    || { tail -40 /tmp/tbt-build-mac.log; die "mac build failed"; }
  local app out
  app=$(find "$DD/Build/Products" -maxdepth 2 -name '*.app' -path '*Debug*' ! -path '*simulator*' | head -1)
  [[ -n "$app" ]] || die "mac .app not found"
  PROJECT_APP_GLOB="${app##*/}/Contents/MacOS"
  # Always tear down the demo app, even if a capture/assertion fails midway.
  trap mac_kill EXIT
  out="$SHOTS/mac/$LOCALE"; mkdir -p "$out"
  rm -f "$out"/mac_*.png
  local i=1
  for tab in "${MAC_TABS[@]}"; do
    mac_kill; sleep 1
    open -n "$app" --args -uiTestDemoMode YES -uiScreenshotTab "$tab"
    local wid="" tries=0
    while [[ -z "$wid" && $tries -lt 20 ]]; do
      sleep 1; wid=$(mac_window_id); tries=$((tries + 1))
    done
    [[ -n "$wid" ]] || { mac_kill; die "mac window not found for $tab"; }
    sleep 4
    local f
    f=$(printf "%s/mac_%02d_%s.png" "$out" "$i" "$tab")
    screencapture -x -o -l"$wid" "$f"
    if [[ ! -s "$f" ]]; then
      die "mac capture produced no image for $tab (grant Screen Recording permission to the controlling terminal in System Settings ▸ Privacy & Security ▸ Screen Recording, then retry)"
    fi
    mac_normalize "$f"
    assert_size "$f" "2880 1800" "2560 1600" "1440 900" "1280 800" "1520 1200" "1640 1200"
    i=$((i + 1))
  done
  mac_kill
}

PROJECT_APP_GLOB="TranscriptionApp"
target="${1:-all}"
case "$target" in
  iphone) do_iphone ;;
  ipad)   do_ipad ;;
  ios)    do_iphone; do_ipad ;;
  mac)    do_mac ;;
  all)    do_iphone; do_ipad; do_mac ;;
  *) die "unknown target '$target' (iphone|ipad|ios|mac|all)" ;;
esac
log "Done: $target"
