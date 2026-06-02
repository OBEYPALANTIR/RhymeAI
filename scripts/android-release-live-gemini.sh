#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
PACKAGE="com.rhymeai.app"
APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"

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

gemini_key="${GEMINI_TEST_KEY:-}"
if [[ -z "$gemini_key" ]]; then
  gemini_key="$(sed -n 's/^geminiTestKey=//p' "$ANDROID_DIR/local.properties" 2>/dev/null | tail -1)"
fi

if [[ -z "$gemini_key" ]]; then
  echo "No Gemini key supplied. Set GEMINI_TEST_KEY or android/local.properties geminiTestKey." >&2
  exit 1
fi

serial="${ANDROID_SERIAL:-}"
if [[ -z "$serial" ]]; then
  serial="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi

if [[ -z "$serial" ]]; then
  echo "No adb device is attached for the Android release live Gemini walkthrough." >&2
  echo "Boot an emulator or attach a device, then rerun this script." >&2
  exit 1
fi

SKIP_INSTALL=1 "$ROOT_DIR/scripts/android-release-smoke.sh"

scan_dir="$(mktemp -d)"
trap 'rm -rf "$scan_dir"' EXIT
unzip -oqq "$APK" -d "$scan_dir/apk"
unzip -oqq "$ANDROID_DIR/app/build/outputs/bundle/release/app-release.aab" -d "$scan_dir/aab"
if rg -a -q 'AI[z]a[0-9A-Za-z_-]+' "$scan_dir"; then
  echo "Release artifact contains a Gemini API key pattern after unzip scan." >&2
  exit 1
fi
if rg -a -F -q "$gemini_key" "$scan_dir"; then
  echo "Release artifact contains the runtime Gemini key after unzip scan." >&2
  exit 1
fi

"$ADB" -s "$serial" uninstall "$PACKAGE" >/dev/null 2>&1 || true
"$ADB" -s "$serial" install "$APK"
"$ADB" -s "$serial" shell pm clear "$PACKAGE" >/dev/null
"$ADB" -s "$serial" logcat -c
"$ADB" -s "$serial" shell am start -W -n "$PACKAGE/.MainActivity" >/dev/null

release_title="Release Gemini $(date +%s)"
release_lyrics="Midnight notes on a borrowed train I keep the hook alive through rain"
release_lyrics_fragment="borrowed train"

dump_ui() {
  "$ADB" -s "$serial" shell uiautomator dump /sdcard/rhymeai-window.xml >/dev/null
  "$ADB" -s "$serial" shell cat /sdcard/rhymeai-window.xml | tr -d '\r'
}

redacted_dump_ui() {
  dump_ui | perl -pe 's/AI[z]a[0-9A-Za-z_-]+/[REDACTED_GEMINI_KEY]/g' |
    perl -0pe 'BEGIN { $key = $ENV{"RHYMEAI_RUNTIME_GEMINI_KEY"} // "" } if ($key ne "") { s/\Q$key\E/[REDACTED_RUNTIME_KEY]/g }'
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
  local mode="$1"
  local needle="$2"
  local timeout="${3:-20}"
  local deadline=$((SECONDS + timeout))
  until node_bounds "$mode" "$needle" >/dev/null; do
    if (( SECONDS >= deadline )); then
      RHYMEAI_RUNTIME_GEMINI_KEY="$gemini_key" redacted_dump_ui >&2 || true
      echo "Timed out waiting for UI node: $needle" >&2
      exit 1
    fi
    sleep 1
  done
}

wait_for_node_with_scroll() {
  local mode="$1"
  local needle="$2"
  local timeout="${3:-20}"
  local deadline=$((SECONDS + timeout))
  until node_bounds "$mode" "$needle" >/dev/null; do
    if (( SECONDS >= deadline )); then
      RHYMEAI_RUNTIME_GEMINI_KEY="$gemini_key" redacted_dump_ui >&2 || true
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

long_press_node() {
  local mode="$1"
  local needle="$2"
  local duration="${3:-1800}"
  local bounds
  bounds="$(node_bounds "$mode" "$needle")"
  read -r x1 y1 x2 y2 <<<"$bounds"
  local preferred_x=$((x1 + 160))
  local x
  if (( preferred_x < x2 )); then
    x="$preferred_x"
  else
    x=$(((x1 + x2) / 2))
  fi
  local y=$(((y1 + y2) / 2))
  "$ADB" -s "$serial" shell input swipe "$x" "$y" "$x" "$y" "$duration" >/dev/null
}

select_rewrite_text() {
  local mode="$1"
  local needle="$2"
  local bounds
  bounds="$(node_bounds "$mode" "$needle")"
  read -r x1 y1 x2 y2 <<<"$bounds"
  local y=$(((y1 + y2) / 2))
  local x
  for x in $((x1 + 160)) $((x1 + 120)) $(((x1 + x2) / 2)); do
    if (( x >= x2 )); then
      x=$(((x1 + x2) / 2))
    fi
    "$ADB" -s "$serial" shell input tap "$x" "$y" >/dev/null || true
    "$ADB" -s "$serial" shell input swipe "$x" "$y" "$x" "$y" 2000 >/dev/null || true
    if node_bounds exact "Rephrase" >/dev/null; then
      return 0
    fi
  done
  return 1
}

input_text() {
  local text="$1"
  local escaped="${text// /%s}"
  "$ADB" -s "$serial" shell input text "$escaped"
}

assert_process_alive() {
  local pid
  pid="$("$ADB" -s "$serial" shell pidof "$PACKAGE" | tr -d '\r' || true)"
  if [[ -z "$pid" ]]; then
    "$ADB" -s "$serial" logcat -d -t 500 | rg -n 'FATAL EXCEPTION|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError' || true
    echo "Release app process is not running." >&2
    exit 1
  fi
}

assert_no_crash_markers() {
  if "$ADB" -s "$serial" logcat -d -t 1000 | rg -n 'FATAL EXCEPTION|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError'; then
    echo "Release live Gemini walkthrough emitted crash markers." >&2
    exit 1
  fi
  if "$ADB" -s "$serial" logcat -d -t 1000 | rg -F -q "$gemini_key"; then
    echo "Release live Gemini walkthrough leaked the runtime key to logcat." >&2
    exit 1
  fi
}

wait_for_node exact "New Song" 30
tap_node exact "New Song"

wait_for_node exact "Settings" 20
tap_node exact "Settings"
wait_for_node exact "AI Provider" 20
wait_for_node exact "Paste your API key here..." 20
tap_node exact "Paste your API key here..."
input_text "$gemini_key"
"$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true
tap_node exact "Save Settings"
wait_for_node exact "Settings saved successfully." 20
tap_node exact "Close"

wait_for_node exact "Song Title..." 20
tap_node exact "Song Title..."
input_text "$release_title"

wait_for_node exact "Start writing your lyrics here..." 20
tap_node exact "Start writing your lyrics here..."
input_text "$release_lyrics"
"$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true
wait_for_node exact "Saved" 10

tap_node exact "UnBlock"
wait_for_node_with_scroll exact "Suggest Next Line" 20
tap_node exact "Suggest Next Line"
wait_for_node contains "AI-generated" 90
"$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true

wait_for_node contains "$release_lyrics_fragment" 20
select_rewrite_text contains "$release_lyrics_fragment" || true
wait_for_node exact "Rephrase" 20
tap_node exact "Rephrase"
wait_for_node contains "Previewing Rephrase" 120
tap_node exact "Cancel"

assert_process_alive
assert_no_crash_markers

echo "Android release live Gemini walkthrough passed on $serial: runtime key entry, live suggestion, live rewrite preview, and release artifact key scan."
