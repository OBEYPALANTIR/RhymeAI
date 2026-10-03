#!/usr/bin/env bash
set -euo pipefail
umask 077

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
serial="$ANDROID_SERIAL"

SKIP_INSTALL=1 "$ROOT_DIR/scripts/android-release-smoke.sh"
APK="$(android_app_build_directory)/outputs/apk/release/app-release.apk"

install_release_apk "$APK"
"$ADB" -s "$serial" logcat -c
"$ADB" -s "$serial" shell am start -W -n "$PACKAGE/.MainActivity" >/dev/null

release_title="Release Walkthrough $(date +%s)"
release_lyrics="Midnight notes on a borrowed train"

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
  local timeout="${3:-20}"
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

input_text() {
  local text="$1"
  local chunk=()
  local word
  read -ra words <<<"$text"
  for word in "${words[@]}"; do
    chunk+=("$word")
    if (( ${#chunk[@]} == 6 )); then
      local joined="${chunk[*]} "
      "$ADB" -s "$serial" shell input text "${joined// /%s}"
      chunk=()
      sleep 0.2
    fi
  done
  if (( ${#chunk[@]} > 0 )); then
    local joined="${chunk[*]} "
    "$ADB" -s "$serial" shell input text "${joined// /%s}"
  fi
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

wait_for_node exact "New Song" 30
tap_node exact "New Song"

wait_for_node exact "Song Title..." 20
tap_node exact "Song Title..."
input_text "$release_title"
"$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true
sleep 1

wait_for_node exact "Start writing your lyrics here..." 20
tap_node exact "Start writing your lyrics here..."
input_text "$release_lyrics"
wait_for_node contains "Midnight notes on a borrowed train" 10

"$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true
wait_for_node exact "Saved" 10

tap_node exact "UnBlock"
wait_for_node_with_scroll exact "Suggest Next Line" 20
tap_node exact "Suggest Next Line"
wait_for_node_with_scroll contains "No API key set" 20
"$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true

wait_for_node exact "Export" 20
tap_node exact "Export"
wait_for_node exact "Export Song" 20
wait_for_node exact "Plain Text" 20
"$ADB" -s "$serial" shell input keyevent KEYCODE_BACK >/dev/null || true

"$ADB" -s "$serial" shell am force-stop "$PACKAGE"
"$ADB" -s "$serial" shell am start -W -n "$PACKAGE/.MainActivity" >/dev/null
wait_for_node exact "Load Song" 30
tap_node exact "Load Song"
wait_for_node contains "$release_title" 20
tap_node contains "$release_title"
wait_for_node contains "$release_title" 20
wait_for_node contains "Midnight notes on a borrowed train" 20

assert_process_alive

if "$ADB" -s "$serial" logcat -d -t 500 | rg -n 'FATAL EXCEPTION|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError'; then
  echo "Release walkthrough emitted crash markers." >&2
  exit 1
fi

echo "Android release walkthrough passed on $serial: create, save, no-key suggestion, export surface, force-stop, reopen, and persisted lyrics."
