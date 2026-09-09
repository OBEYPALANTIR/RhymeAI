#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="${IOS_BUNDLE_ID:-ShaydeTree.Writers-Block}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
source "$ROOT_DIR/scripts/ios-release-safety.sh"

PHONE_ID="${IOS_SIMULATOR_ID:-}"
IPAD_ID="${IOS_IPAD_SIMULATOR_ID:-}"
require_simulator_id IOS_SIMULATOR_ID "$PHONE_ID"
require_simulator_id IOS_IPAD_SIMULATOR_ID "$IPAD_ID"
if [[ "$(printf '%s' "$PHONE_ID" | tr '[:lower:]' '[:upper:]')" == "$(printf '%s' "$IPAD_ID" | tr '[:lower:]' '[:upper:]')" ]]; then
  echo "Select distinct disposable iPhone and iPad simulator UDIDs." >&2
  exit 1
fi
PHONE_PROFILE="$(validate_simulator "$PHONE_ID" iPhone)"
IPAD_PROFILE="$(validate_simulator "$IPAD_ID" iPad)"
require_uninstalled_app "$PHONE_ID" "$BUNDLE_ID"
require_uninstalled_app "$IPAD_ID" "$BUNDLE_ID"

if [[ "${SKIP_BUILD:-0}" == "1" && -z "${IOS_VISUAL_AUDIT_DERIVED_DATA:-}" ]]; then
  echo "SKIP_BUILD=1 requires IOS_VISUAL_AUDIT_DERIVED_DATA pointing to the intended existing Release build." >&2
  exit 1
fi
WORK_DIR="$(create_work_directory "${IOS_VISUAL_AUDIT_WORK_DIR:-}" rhymeai-ios-release-visual-audit)"
DERIVED_DATA="${IOS_VISUAL_AUDIT_DERIVED_DATA:-$WORK_DIR/DerivedData}"
SIM_APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/Writers Block.app"
OUTPUT_DIR="${IOS_VISUAL_AUDIT_OUTPUT_DIR:-${IOS_VISUAL_AUDIT_DIR:-}}"
if [[ -n "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(create_work_directory "$OUTPUT_DIR" unused)"
else
  mkdir -p "$ROOT_DIR/artifacts/ios-release-visual-audit"
  OUTPUT_DIR="$(mktemp -d "$ROOT_DIR/artifacts/ios-release-visual-audit/$RUN_ID.XXXXXX")"
fi
SCREENSHOT_DIR="$OUTPUT_DIR/screenshots"
REPORT="$OUTPUT_DIR/report.txt"
mkdir "$SCREENSHOT_DIR"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  IOS_RELEASE_WORK_DIR="$WORK_DIR/build" \
    IOS_RELEASE_DERIVED_DATA="$DERIVED_DATA" \
    SKIP_SIM_LAUNCH=1 \
    SKIP_ARCHIVE=1 \
    "$ROOT_DIR/scripts/ios-release-smoke.sh"
fi

if [[ ! -x "$SIM_APP/Writers Block" ]]; then
  echo "Release simulator app binary was not found at $SIM_APP/Writers Block." >&2
  exit 1
fi

require_app_bundle "$SIM_APP" "$BUNDLE_ID"
python3 "$ROOT_DIR/scripts/scan-release-content.py" --binary "$SIM_APP/Writers Block"

capture_profile() {
  local udid="$1"
  local family="$2"
  local profile="$3"
  local appearance="$4"
  local launch_output
  local app_pid
  xcrun simctl ui "$udid" appearance "$appearance"
  launch_output="$(xcrun simctl launch "$udid" "$BUNDLE_ID")"
  app_pid="${launch_output##*: }"
  sleep "${IOS_VISUAL_AUDIT_SETTLE_SECONDS:-4}"
  if [[ -z "$app_pid" || ! "$app_pid" =~ ^[0-9]+$ ]] || ! ps -p "$app_pid" >/dev/null 2>&1; then
    echo "Release app process did not stay alive on $profile | $appearance." >&2
    exit 1
  fi

  local screenshot="$SCREENSHOT_DIR/$family-$udid-$appearance.png"
  xcrun simctl io "$udid" screenshot "$screenshot" >/dev/null
  if [[ ! -s "$screenshot" ]]; then
    echo "Simulator screenshot was not produced: $screenshot" >&2
    exit 1
  fi
  printf '%s | %s | %s\n' "$profile" "$appearance" "$screenshot" | tee -a "$REPORT"
  xcrun simctl terminate "$udid" "$BUNDLE_ID"
}

{
  echo "iOS Release visual audit screenshots; human visual review still required"
  echo "Run: $RUN_ID"
  echo "App: $SIM_APP"
  echo ""
} > "$REPORT"

for family in iPhone iPad; do
  if [[ "$family" == iPhone ]]; then
    udid="$PHONE_ID"
    profile="$PHONE_PROFILE"
  else
    udid="$IPAD_ID"
    profile="$IPAD_PROFILE"
  fi
  validate_simulator "$udid" "$family"
  require_uninstalled_app "$udid" "$BUNDLE_ID"
  xcrun simctl install "$udid" "$SIM_APP"
  capture_profile "$udid" "$family" "$profile" light
  capture_profile "$udid" "$family" "$profile" dark
done

echo "iOS Release screenshot capture and process checks completed; human visual review required. Screenshots: $SCREENSHOT_DIR"
