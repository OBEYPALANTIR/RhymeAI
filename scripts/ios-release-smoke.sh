#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
SCHEME="${IOS_SCHEME:-Writers Block}"
DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
WORK_DIR="${IOS_RELEASE_WORK_DIR:-${TMPDIR:-/tmp}/rhymeai-ios-release}"
DERIVED_DATA="${IOS_RELEASE_DERIVED_DATA:-$WORK_DIR/DerivedData}"
ARCHIVE_PATH="${IOS_ARCHIVE_PATH:-$WORK_DIR/WritersBlock.xcarchive}"
BUNDLE_ID="${IOS_BUNDLE_ID:-ShaydeTree.Writers-Block}"

scan_binary() {
  local binary="$1"
  if strings "$binary" | rg -q 'AI[z]a'; then
    echo "Release binary contains a Gemini API key pattern: $binary" >&2
    exit 1
  fi
  echo "Release binary key scan passed: $binary"
}

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
    if runtime_suffix and runtime_suffix not in runtime:
        continue
    for device in devices:
        if device.get("name") == name and device.get("isAvailable", False):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
PY
}

rm -rf "$DERIVED_DATA"
mkdir -p "$(dirname "$DERIVED_DATA")" "$(dirname "$ARCHIVE_PATH")"

# This repo lives under Documents/iCloud on Tyler's machine. FileProvider and
# provenance xattrs can be copied into the .app and make codesign reject archives.
xattr -rc "$ROOT_DIR/Writers Block/Writers Block" 2>/dev/null || true

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
scan_binary "$SIM_BINARY"

if [[ "${SKIP_SIM_LAUNCH:-0}" != "1" ]]; then
  simulator_id="${IOS_SIMULATOR_ID:-}"
  if [[ -z "$simulator_id" ]]; then
    simulator_name="$(printf '%s\n' "$DESTINATION" | sed -n 's/.*name=\([^,]*\).*/\1/p')"
    simulator_os="$(printf '%s\n' "$DESTINATION" | sed -n 's/.*OS=\([^,]*\).*/iOS \1/p')"
    simulator_name="${simulator_name:-iPhone 17 Pro}"
    simulator_os="${simulator_os:-iOS 26.5}"
    simulator_id="$(find_simulator "$simulator_name" "$simulator_os" || true)"
  fi
  if [[ -z "$simulator_id" ]]; then
    if [[ "${REQUIRE_SIM:-0}" == "1" ]]; then
      echo "No matching iPhone 17 Pro OS 26.5 simulator is available." >&2
      exit 1
    fi
    echo "No matching simulator found; Release simulator launch skipped."
  else
    xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$simulator_id" -b
    xcrun simctl uninstall "$simulator_id" "$BUNDLE_ID" >/dev/null 2>&1 || true
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
  fi
else
  echo "Skipping Release simulator launch because SKIP_SIM_LAUNCH=1."
fi

if [[ "${SKIP_ARCHIVE:-0}" == "1" ]]; then
  echo "Skipping iOS archive because SKIP_ARCHIVE=1."
  exit 0
fi

rm -rf "$ARCHIVE_PATH"
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
