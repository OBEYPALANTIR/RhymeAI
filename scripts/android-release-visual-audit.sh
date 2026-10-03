#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
source "$ROOT_DIR/scripts/android-release-common.sh"
PACKAGE="com.rhymeai.app"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUTPUT_DIR="${ANDROID_VISUAL_OUTPUT_DIR:-$ROOT_DIR/artifacts/android-release-visual-audit/$RUN_ID}"
SCREENSHOT_DIR="$OUTPUT_DIR/screenshots"
REPORT="$OUTPUT_DIR/report.txt"
if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]]; then
  echo "Refusing to reuse existing visual audit output: $OUTPUT_DIR" >&2
  exit 1
fi

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
if [[ ! -x "$ADB" ]]; then
  ADB="adb"
fi
require_empty_android_target

mkdir -p "$(dirname "$OUTPUT_DIR")"
mkdir "$OUTPUT_DIR"
mkdir "$SCREENSHOT_DIR"

serial="${ANDROID_SERIAL:-}"
original_font_scale=""
original_night_mode=""
device_class="phone"
wm_size=""
wm_density=""
sdk_version=""
model_name=""
screen_width=1080
screen_height=2400

capture_android_visual_state
cleanup() {
  local result=$?
  trap - EXIT
  restore_android_visual_state || result=1
  exit "$result"
}
trap cleanup EXIT

SKIP_INSTALL=1 "$ROOT_DIR/scripts/android-release-smoke.sh"
APK="$(android_app_build_directory)/outputs/apk/release/app-release.apk"

install_release_apk "$APK"
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
  local swipe_x=$((screen_width / 2))
  local swipe_start=$((screen_height * 85 / 100))
  local swipe_end=$((screen_height * 30 / 100))
  until node_bounds "$mode" "$needle" >/dev/null; do
    if (( SECONDS >= deadline )); then
      dump_ui >&2 || true
      echo "Timed out waiting for UI node after scrolling: $needle" >&2
      exit 1
    fi
    "$ADB" -s "$serial" shell input swipe "$swipe_x" "$swipe_start" "$swipe_x" "$swipe_end" 450 >/dev/null || true
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
  local markers
  markers="$("$ADB" -s "$serial" logcat -d -t 700 | rg -n 'FATAL EXCEPTION|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError' || true)"
  if [[ -n "$markers" ]] && printf '%s\n' "$markers" | rg -q "$PACKAGE|FATAL EXCEPTION|ClassNotFoundException|NoSuchMethodError"; then
    printf '%s\n' "$markers" >&2
    echo "Release visual audit emitted app crash markers." >&2
    exit 1
  fi
  if [[ -z "$("$ADB" -s "$serial" shell pidof "$PACKAGE" | tr -d '\r' || true)" ]]; then
    printf '%s\n' "$markers" >&2
    echo "Release app process is not running." >&2
    exit 1
  fi
}

classify_device() {
  model_name="$("$ADB" -s "$serial" shell getprop ro.product.model | tr -d '\r')"
  sdk_version="$("$ADB" -s "$serial" shell getprop ro.build.version.sdk | tr -d '\r')"
  wm_size="$("$ADB" -s "$serial" shell wm size | tr -d '\r')"
  wm_density="$("$ADB" -s "$serial" shell wm density | tr -d '\r')"

  local size density smallest_dp
  size="$(printf '%s\n' "$wm_size" | sed -n 's/.*: *\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' | tail -1)"
  density="$(printf '%s\n' "$wm_density" | sed -n 's/.*: *\([0-9][0-9]*\).*/\1/p' | tail -1)"
  if [[ -n "$size" && -n "$density" ]]; then
    read -r screen_width screen_height <<<"$size"
    smallest_dp="$(awk -v w="$screen_width" -v h="$screen_height" -v d="$density" 'BEGIN { s = w < h ? w : h; printf "%.0f", s * 160 / d }')"
    if (( smallest_dp >= 600 )); then
      device_class="tablet"
    fi
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
  classify_device
  echo "Device: $serial"
  echo "Model: $model_name"
  echo "SDK: $sdk_version"
  echo "$wm_size"
  echo "$wm_density"
  echo "Classified profile: $device_class"
  if [[ "$device_class" == "tablet" ]]; then
    echo "Tablet coverage: exercised by this tablet-profile audit."
  else
    echo "Tablet coverage: not exercised by this phone-profile audit; rerun with ANDROID_SERIAL pointed at a fresh disposable tablet emulator."
  fi
  echo
} >"$REPORT"

capture_launch_profile "$device_class-light" "no" "1.0"
capture_launch_profile "$device_class-dark" "yes" "1.0"
capture_launch_profile "$device_class-large-font" "no" "1.3"
capture_populated_flow

echo "Android release visual audit passed on $serial."
echo "Screenshots: $SCREENSHOT_DIR"
echo "Report: $REPORT"
