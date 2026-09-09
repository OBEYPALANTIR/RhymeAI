#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
SCHEME="${IOS_SCHEME:-Writers Block}"
BUNDLE_ID="${IOS_BUNDLE_ID:-ShaydeTree.Writers-Block}"
source "$ROOT_DIR/scripts/ios-release-safety.sh"

if [[ "${SKIP_SIM_LAUNCH:-0}" != "1" ]]; then
  simulator_id="${IOS_SIMULATOR_ID:-}"
  require_simulator_id IOS_SIMULATOR_ID "$simulator_id"
  validate_simulator "$simulator_id" iPhone
  require_uninstalled_app "$simulator_id" "$BUNDLE_ID"
  DESTINATION="platform=iOS Simulator,id=$simulator_id"
else
  DESTINATION="${IOS_DESTINATION:-generic/platform=iOS Simulator}"
fi

WORK_DIR="$(create_work_directory "${IOS_RELEASE_WORK_DIR:-}" rhymeai-ios-release)"
DERIVED_DATA="${IOS_RELEASE_DERIVED_DATA:-$WORK_DIR/DerivedData}"
ARCHIVE_PATH="${IOS_ARCHIVE_PATH:-$WORK_DIR/WritersBlock.xcarchive}"
require_new_path "$DERIVED_DATA"
if [[ "${SKIP_ARCHIVE:-0}" != "1" ]]; then
  require_new_path "$ARCHIVE_PATH"
  mkdir -p "$(dirname "$ARCHIVE_PATH")"
fi
mkdir -p "$(dirname "$DERIVED_DATA")"
echo "iOS Release work directory: $WORK_DIR"

scan_binary() {
  python3 "$ROOT_DIR/scripts/scan-release-content.py" --binary "$1"
}

xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED="${IOS_SIM_CODE_SIGNING_ALLOWED:-YES}"

SIM_APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/Writers Block.app"
SIM_BINARY="$SIM_APP/Writers Block"
if [[ ! -x "$SIM_BINARY" ]]; then
  echo "Release simulator app binary was not found at $SIM_BINARY." >&2
  exit 1
fi
require_app_bundle "$SIM_APP" "$BUNDLE_ID"
scan_binary "$SIM_BINARY"

if [[ "${SKIP_SIM_LAUNCH:-0}" != "1" ]]; then
  validate_simulator "$simulator_id" iPhone
  require_uninstalled_app "$simulator_id" "$BUNDLE_ID"
  xcrun simctl install "$simulator_id" "$SIM_APP"
  launch_output="$(xcrun simctl launch "$simulator_id" "$BUNDLE_ID")"
  echo "$launch_output"
  app_pid="${launch_output##*: }"
  sleep 3
  if [[ -z "$app_pid" || ! "$app_pid" =~ ^[0-9]+$ ]] || ! ps -p "$app_pid" >/dev/null 2>&1; then
    echo "Release simulator app process did not stay alive after launch." >&2
    exit 1
  fi
  echo "Release simulator app installed and launched on $simulator_id."
else
  echo "Skipping Release simulator launch because SKIP_SIM_LAUNCH=1."
fi

if [[ "${SKIP_ARCHIVE:-0}" == "1" ]]; then
  echo "Skipping iOS archive because SKIP_ARCHIVE=1."
  exit 0
fi

require_new_path "$ARCHIVE_PATH"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA"

ARCHIVE_BINARY="$ARCHIVE_PATH/Products/Applications/Writers Block.app/Writers Block"
if [[ ! -x "$ARCHIVE_BINARY" ]]; then
  echo "Archive app binary was not found at $ARCHIVE_BINARY." >&2
  exit 1
fi
scan_binary "$ARCHIVE_BINARY"

echo "iOS Release archive produced at $ARCHIVE_PATH."
