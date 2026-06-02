#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="${IOS_BUNDLE_ID:-ShaydeTree.Writers-Block}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${IOS_VISUAL_AUDIT_OUTPUT_DIR:-${IOS_VISUAL_AUDIT_DIR:-$ROOT_DIR/artifacts/ios-release-visual-audit/$RUN_ID}}"
WORK_DIR="${IOS_VISUAL_AUDIT_WORK_DIR:-${TMPDIR:-/tmp}/rhymeai-ios-release-visual-audit/$RUN_ID}"
DERIVED_DATA="${IOS_VISUAL_AUDIT_DERIVED_DATA:-$WORK_DIR/DerivedData}"
SIM_APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/Writers Block.app"
SCREENSHOT_DIR="$OUTPUT_DIR/screenshots"
REPORT="$OUTPUT_DIR/report.txt"

mkdir -p "$SCREENSHOT_DIR"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  IOS_RELEASE_WORK_DIR="$WORK_DIR/build" \
    IOS_RELEASE_DERIVED_DATA="$DERIVED_DATA" \
    SKIP_SIM_LAUNCH=1 \
    SKIP_ARCHIVE=1 \
    "$ROOT_DIR/scripts/ios-release-smoke.sh"
fi

if [[ ! -d "$SIM_APP" ]]; then
  echo "Release simulator app was not found at $SIM_APP." >&2
  exit 1
fi

find_simulator() {
  local name="$1"
  local os="$2"
  local simctl_json
  simctl_json="$(xcrun simctl list devices available --json)"
  SIMCTL_JSON="$simctl_json" /usr/bin/python3 - "$name" "$os" <<'PY'
import json
import os
import sys

name, os_name = sys.argv[1], sys.argv[2]
runtime_suffix = os_name.replace("iOS ", "iOS-").replace(".", "-")
data = json.loads(os.environ["SIMCTL_JSON"])
for runtime, devices in data.get("devices", {}).items():
    if runtime_suffix not in runtime:
        continue
    for device in devices:
        if device.get("name") == name and device.get("isAvailable", False):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
PY
}

slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//'
}

capture_profile() {
  local name="$1"
  local os="$2"
  local appearance="$3"
  local udid
  if ! udid="$(find_simulator "$name" "$os")"; then
    echo "No available simulator found for $name $os." >&2
    exit 1
  fi

  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl ui "$udid" appearance "$appearance"
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$SIM_APP"
  local launch_output
  local app_pid
  launch_output="$(xcrun simctl launch "$udid" "$BUNDLE_ID")"
  app_pid="${launch_output##*: }"
  sleep "${IOS_VISUAL_AUDIT_SETTLE_SECONDS:-4}"

  if [[ -z "$app_pid" || ! "$app_pid" =~ ^[0-9]+$ ]] || ! ps -p "$app_pid" >/dev/null 2>&1; then
    echo "Release app process did not stay alive on $name $os $appearance." >&2
    exit 1
  fi

  local screenshot="$SCREENSHOT_DIR/$(slug "$name-$os-$appearance").png"
  xcrun simctl io "$udid" screenshot "$screenshot" >/dev/null
  printf '%s | %s | %s | %s\n' "$name" "$os" "$appearance" "$screenshot" | tee -a "$REPORT"

  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ "${IOS_VISUAL_AUDIT_SHUTDOWN:-1}" == "1" ]]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi
}

: > "$REPORT"
echo "iOS Release visual audit screenshots" >> "$REPORT"
echo "Run: $RUN_ID" >> "$REPORT"
echo "App: $SIM_APP" >> "$REPORT"
echo "" >> "$REPORT"

capture_profile "iPhone 17 Pro" "iOS 26.5" "light"
capture_profile "iPhone 17 Pro" "iOS 26.5" "dark"
capture_profile "iPad Pro 13-inch (M5)" "iOS 26.5" "light"
capture_profile "iPad Pro 13-inch (M5)" "iOS 26.5" "dark"

echo "iOS Release visual audit passed. Screenshots: $SCREENSHOT_DIR"
