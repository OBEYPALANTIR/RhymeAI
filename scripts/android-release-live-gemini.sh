#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
gemini_key="${GEMINI_TEST_KEY:-}"
export -n gemini_key
unset GEMINI_TEST_KEY

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
source "$ROOT_DIR/scripts/android-release-common.sh"
PACKAGE="com.rhymeai.app"

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

if [[ -z "$gemini_key" ]]; then
  gemini_key="$(sed -n 's/^geminiTestKey=//p' "$ANDROID_DIR/local.properties" 2>/dev/null | tail -1)"
fi

if [[ -z "$gemini_key" ]]; then
  echo "No Gemini key supplied. Set GEMINI_TEST_KEY or android/local.properties geminiTestKey." >&2
  exit 1
fi

serial="$ANDROID_SERIAL"

SKIP_INSTALL=1 "$ROOT_DIR/scripts/android-release-smoke.sh"
APP_BUILD_DIR="$(android_app_build_directory)"
APK="$APP_BUILD_DIR/outputs/apk/release/app-release.apk"
printf '%s' "$gemini_key" | python3 "$ROOT_DIR/scripts/scan-release-content.py" --secret-stdin "$APK" "$APP_BUILD_DIR/outputs/bundle/release/app-release.aab"

install_release_apk "$APK"
"$ADB" -s "$serial" logcat -c
"$ADB" -s "$serial" shell am start -W -n "$PACKAGE/.MainActivity" >/dev/null

release_title="Release Gemini $(date +%s)"
release_lyrics="Midnight notes on a borrowed train I keep the hook alive through rain"
release_lyrics_fragment="borrowed train"

dump_ui() {
  "$ADB" -s "$serial" shell uiautomator dump /sdcard/rhymeai-window.xml >/dev/null
  "$ADB" -s "$serial" shell cat /sdcard/rhymeai-window.xml | tr -d '\r'
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
      echo "UI diagnostic content withheld to protect runtime credentials." >&2
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
      echo "UI diagnostic content withheld to protect runtime credentials." >&2
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
  pid="$("$ADB" -s "$serial" shell pidof "$PACKAGE" | tr -d '\r')" || return 1
  if [[ -z "$pid" ]]; then
    echo "Release app process is not running; log content withheld." >&2
    return 1
  fi
}

assert_no_crash_markers() {
  local logs scan_status
  logs="$("$ADB" -s "$serial" logcat -d -t 1000 2>/dev/null)" || {
    echo "Could not read release diagnostics." >&2; return 1;
  }
  if printf '%s\n' "$logs" | rg 'FATAL EXCEPTION|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError' >/dev/null; then
    echo "Release live Gemini walkthrough emitted crash markers; content withheld." >&2
    return 1
  else
    scan_status=$?
    [[ "$scan_status" == 1 ]] || return 1
  fi
  if printf '%s\n' "$logs" | rg -F -f <(printf '%s\n' "$gemini_key") >/dev/null; then
    echo "Release live Gemini walkthrough leaked the runtime key to logcat." >&2
    return 1
  else
    scan_status=$?
    [[ "$scan_status" == 1 ]] || return 1
  fi
}

wait_for_node exact "New Song" 30
tap_node exact "New Song"

wait_for_node exact "Settings" 20
tap_node exact "Settings"
wait_for_node exact "AI Provider" 20
wait_for_node exact "Paste your API key here..." 20
tap_node exact "Paste your API key here..."
if ! printf '%s\n' "$gemini_key" | "$ADB" -s "$serial" shell 'IFS= read -r key; input text "$key"' >/dev/null 2>&1; then
  echo "Could not enter the runtime key; device response withheld." >&2
  exit 1
fi
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
