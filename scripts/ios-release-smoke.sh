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
  CODE_SIGNING_ALLOWED=NO

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
    simulator_id="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone 17 Pro/ && /26.5/ { print $2; exit }')"
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
    xcrun simctl launch "$simulator_id" "$BUNDLE_ID"
    sleep 3
    if ! xcrun simctl spawn "$simulator_id" pgrep -f "Writers Block" >/dev/null 2>&1; then
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
