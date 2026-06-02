#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
PACKAGE="com.rhymeai.app"
APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUTPUT_DIR="${ANDROID_VISUAL_OUTPUT_DIR:-$ROOT_DIR/artifacts/android-release-visual-audit/$RUN_ID}"
SCREENSHOT_DIR="$OUTPUT_DIR/screenshots"
REPORT="$OUTPUT_DIR/report.txt"

if [[ -z "${JAVA_HOME:-}" && -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi

if [[ -z "${ANDROID_HOME:-}" ]]; then
  ANDROID_HOME="$(sed -n 's/^sdk.dir=//p' "$ANDROID_DIR/local.properties" 2>/dev/null || true)"
  export ANDROID_HOME
fi

if [[ -z "${ANDROID_HOME:-}" || ! -d "$ANDROID_HOME" ]]; then
  echo "ANDROID_HOME is not set and android/local.properties did not provide a valid sdk.dir." >&2
  exit 1
fi

ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR="$ANDROID_HOME/emulator/emulator"
if [[ ! -x "$ADB" ]]; then
  ADB="adb"
fi
if [[ ! -x "$EMULATOR" ]]; then
  EMULATOR="emulator"
fi

mkdir -p "$SCREENSHOT_DIR"

serial="${ANDROID_SERIAL:-}"
owned_emulator=0
original_font_scale=""

device_serial() {
  "$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }'
}

wait_for_boot() {
  local target="$1"
  local timeout="${2:-180}"
  local deadline=$((SECONDS + timeout))
  "$ADB" -s "$target" wait-for-device
  until [[ "$("$ADB" -s "$target" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for Android device boot: $target" >&2
      exit 1
    fi
    sleep 2
  done
  "$ADB" -s "$target" shell input keyevent KEYCODE_WAKEUP >/dev/null || true
  "$ADB" -s "$target" shell wm dismiss-keyguard >/dev/null || true
}

if [[ -z "$serial" ]]; then
  serial="$(device_serial)"
fi

if [[ -z "$serial" ]]; then
  avd_name="${ANDROID_AVD_NAME:-}"
  if [[ -z "$avd_name" ]]; then
    avd_name="$("$EMULATOR" -list-avds 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$avd_name" ]]; then
    echo "No adb device is attached and no Android AVD is available." >&2
    exit 1
  fi
  "$EMULATOR" -avd "$avd_name" -no-snapshot-save -no-audio -no-boot-anim \
    >"$OUTPUT_DIR/emulator.log" 2>&1 &
  owned_emulator=1

  deadline=$((SECONDS + 120))
  until serial="$(device_serial)"; [[ -n "$serial" ]]; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for emulator device from AVD: $avd_name" >&2
      exit 1
    fi
    sleep 2
  done
fi

cleanup() {
  if [[ -n "${serial:-}" ]]; then
    if [[ -n "$original_font_scale" && "$original_font_scale" != "null" ]]; then
      "$ADB" -s "$serial" shell settings put system font_scale "$original_font_scale" >/dev/null 2>&1 || true
    fi
    "$ADB" -s "$serial" shell cmd uimode night no >/dev/null 2>&1 || true
  fi
  if [[ "$owned_emulator" == "1" && "${ANDROID_VISUAL_SHUTDOWN_EMULATOR:-0}" == "1" ]]; then
    "$ADB" -s "$serial" emu kill >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_boot "$serial"
original_font_scale="$("$ADB" -s "$serial" shell settings get system font_scale 2>/dev/null | tr -d '\r' || true)"

SKIP_INSTALL=1 "$ROOT_DIR/scripts/android-release-smoke.sh"

"$ADB" -s "$serial" uninstall "$PACKAGE" >/dev/null 2>&1 || true
"$ADB" -s "$serial" install "$APK"
"$ADB" -s "$serial" shell pm clear "$PACKAGE" >/dev/null
"$ADB" -s "$serial" logcat -c

dump_ui() {
  "$ADB" -s "$serial" shell uiautomator dump /sdcard/rhymeai-window.xml >/dev/null
  "$ADB" -s "$serial" shell cat /sdcard/rhymeai-window.xml | tr -d '\r'
}

node_exists() {
  local needle="$1"
  dump_ui | perl -MHTML::Entities -0e '
    my ($needle) = @ARGV;
    my $xml = do { local $/; <STDIN> };
    while ($xml =~ /<node\b([^>]*)>/g) {
      my $node = $1;
      my ($text) = $node =~ /\btext="([^"]*)"/;
      my ($desc) = $node =~ /\bcontent-desc="([^"]*)"/;
      $text = defined $text ? HTML::Entities::decode_entities($text) : "";
      $desc = defined $desc ? HTML::Entities::decode_entities($desc) : "";
      exit 0 if $text eq $needle || $desc eq $needle;
    }
    exit 1;
  ' "$needle"
}

node_bounds() {
  local mode="$1"
  local needle="$2"
  dump_ui | perl -MHTML::Entities -0e '
    my ($mode, $needle) = @ARGV;
    my $xml = do { local $/; <STDIN> };
    while ($xml =~ /<node\b([^>]*)>/g) {
      my $node = $1;
      my ($text) = $node =~ /\btext="([^"]*)"/;
      my ($desc) = $node =~ /\bcontent-desc="([^"]*)"/;
      $text = defined $text ? HTML::Entities::decode_entities($text) : "";
      $desc = defined $desc ? HTML::Entities::decode_entities($desc) : "";
      my $match = $mode eq "contains"
        ? (($text ne "" && index($text, $needle) >= 0) || ($desc ne "" && index($desc, $needle) >= 0))
        : ($text eq $needle || $desc eq $needle);
      if ($match && $node =~ /bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/) {
        print "$1 $2 $3 $4\n";
        exit 0;
      }
    }
    exit 1;
  ' "$mode" "$needle"
}

wait_for_node() {
  local needle="$1"
  local timeout="${2:-30}"
  local deadline=$((SECONDS + timeout))
  until node_exists "$needle"; do
    if (( SECONDS >= deadline )); then
      dump_ui >&2 || true
      echo "Timed out waiting for UI node: $needle" >&2
      exit 1
    fi
    sleep 1
  done
}

wait_for_node_with_scroll() {
  local mode="$1"
  local needle="$2"
  local timeout="${3:-30}"
  local deadline=$((SECONDS + timeout))
  until node_bounds "$mode" "$needle" >/dev/null; do
    if (( SECONDS >= deadline )); then
      dump_ui >&2 || true
      echo "Timed out waiting for UI node after scrolling: $needle" >&2
      exit 1
    fi
    "$ADB" -s "$serial" shell input swipe 540 2100 540 700 450 >/dev/null || true
    sleep 1
  done
}

tap_node() {
  local mode="$1"
  local needle="$2"
  local bounds
  bounds="$(node_bounds "$mode" "$needle")"
  read -r x1 y1 x2 y2 <<<"$bounds"
  "$ADB" -s "$serial" shell input tap "$(((x1 + x2) / 2))" "$(((y1 + y2) / 2))"
}

tap_node_with_scroll() {
  local mode="$1"
  local needle="$2"
  wait_for_node_with_scroll "$mode" "$needle" 30
  tap_node "$mode" "$needle"
}

input_text() {
  local text="$1"
  local escaped="${text// /%s}"
  "$ADB" -s "$serial" shell input text "$escaped"
}

assert_no_crash_markers() {
  if "$ADB" -s "$serial" logcat -d -t 500 | rg -n 'FATAL EXCEPTION|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError'; then
    echo "Release visual audit emitted crash markers." >&2
    exit 1
  fi
}

launch_profile() {
  local night_mode="$1"
  local font_scale="$2"
  "$ADB" -s "$serial" shell cmd uimode night "$night_mode" >/dev/null
  "$ADB" -s "$serial" shell settings put system font_scale "$font_scale" >/dev/null
  "$ADB" -s "$serial" shell am force-stop "$PACKAGE" >/dev/null || true
  "$ADB" -s "$serial" shell am start -W -n "$PACKAGE/.MainActivity" >/dev/null
  wait_for_node "New Song" 30
  sleep 2
}

capture_screen() {
  local slug="$1"
  local screenshot="$SCREENSHOT_DIR/$slug.png"
  "$ADB" -s "$serial" exec-out screencap -p >"$screenshot"

  if [[ ! -s "$screenshot" || "$(wc -c <"$screenshot" | tr -d ' ')" -lt 1024 ]]; then
    echo "Screenshot was not captured or is unexpectedly small: $screenshot" >&2
    exit 1
  fi
  printf '%s\n' "$screenshot" >>"$REPORT"
}

capture_launch_profile() {
  local slug="$1"
  local night_mode="$2"
  local font_scale="$3"
  launch_profile "$night_mode" "$font_scale"
  printf '\n%s\tmode=%s\tfont_scale=%s\n' "$slug" "$night_mode" "$font_scale" >>"$REPORT"
  capture_screen "$slug"
  assert_no_crash_markers
}

capture_populated_flow() {
  local night_mode="no"
  local font_scale="1.0"
  local release_title="Visual Audit $(date +%s)"
  local release_lyrics="Midnight notes on a borrowed train I keep the hook alive through rain"

  launch_profile "$night_mode" "$font_scale"
  printf '\npopulated-flow\tmode=%s\tfont_scale=%s\n' "$night_mode" "$font_scale" >>"$REPORT"

  tap_node exact "New Song"
  wait_for_node "Song Title..." 20
  tap_node exact "Song Title..."
  input_text "$release_title"

  wait_for_node "Start writing your lyrics here..." 20
  tap_node exact "Start writing your lyrics here..."
  input_text "$release_lyrics"
  "$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true
  wait_for_node "Saved" 10
  sleep 1
  capture_screen "populated-editor"

  tap_node exact "UnBlock"
  wait_for_node_with_scroll exact "Suggest Next Line" 20
  sleep 1
  capture_screen "assistant-panel"
  "$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true

  tap_node_with_scroll exact "Export"
  wait_for_node "Export Song" 20
  wait_for_node "Plain Text" 20
  sleep 1
  capture_screen "export-sheet"
  "$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true

  assert_no_crash_markers
}

{
  echo "Android release visual audit"
  echo "Run: $RUN_ID"
  echo "Device: $serial"
  "$ADB" -s "$serial" shell getprop ro.product.model | tr -d '\r' | sed 's/^/Model: /'
  "$ADB" -s "$serial" shell getprop ro.build.version.sdk | tr -d '\r' | sed 's/^/SDK: /'
  "$ADB" -s "$serial" shell wm size | tr -d '\r'
  "$ADB" -s "$serial" shell wm density | tr -d '\r'
  echo "Tablet coverage: not exercised by this phone-profile audit; rerun with ANDROID_SERIAL or ANDROID_AVD_NAME pointed at a tablet emulator/device."
  echo
} >"$REPORT"

capture_launch_profile "phone-light" "no" "1.0"
capture_launch_profile "phone-dark" "yes" "1.0"
capture_launch_profile "phone-large-font" "no" "1.3"
capture_populated_flow

echo "Android release visual audit passed on $serial."
echo "Screenshots: $SCREENSHOT_DIR"
echo "Report: $REPORT"
