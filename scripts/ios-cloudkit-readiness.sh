#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
SCHEME="${IOS_SCHEME:-Writers Block}"
DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
DERIVED_DATA="${IOS_CLOUDKIT_DERIVED_DATA:-${TMPDIR:-/tmp}/rhymeai-ios-cloudkit-readiness/DerivedData}"
APP_SOURCE="$ROOT_DIR/Writers Block/Writers Block/Writers_BlockApp.swift"
INFO_PLIST="$ROOT_DIR/Writers Block/Writers-Block-Info.plist"
ENTITLEMENTS="$ROOT_DIR/Writers Block/Writers Block/Writers Block.entitlements"

require_text() {
  local pattern="$1"
  local file="$2"
  local message="$3"
  if ! rg -q "$pattern" "$file"; then
    echo "$message" >&2
    exit 1
  fi
}

require_plist_value() {
  local plist="$1"
  local command="$2"
  local expected="$3"
  local value
  value="$(/usr/libexec/PlistBuddy -c "$command" "$plist" 2>/dev/null || true)"
  if [[ "$value" != "$expected" ]]; then
    echo "Expected '$expected' from '$command' in $plist, got '${value:-missing}'." >&2
    exit 1
  fi
}

require_text 'cloudKitDatabase: \.private\("iCloud\.ShaydeTree\.Writers-Block"\)' \
  "$APP_SOURCE" \
  "Writers_BlockApp.swift is not configured for the expected private CloudKit database."

if rg -q '^\s*@Attribute\(\.unique\)' "$ROOT_DIR/Writers Block/Writers Block/Models"; then
  echo "CloudKit-backed SwiftData models must not use @Attribute(.unique)." >&2
  exit 1
fi

require_plist_value "$ENTITLEMENTS" \
  "Print :com.apple.developer.icloud-container-identifiers:0" \
  "iCloud.ShaydeTree.Writers-Block"
require_plist_value "$ENTITLEMENTS" \
  "Print :com.apple.developer.icloud-services:0" \
  "CloudKit"
require_plist_value "$INFO_PLIST" \
  "Print :UIBackgroundModes:0" \
  "remote-notification"

rm -rf "$DERIVED_DATA"
xattr -rc "$ROOT_DIR/Writers Block/Writers Block" 2>/dev/null || true

xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

BUILT_INFO_PLIST="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Writers Block.app/Info.plist"
if [[ ! -f "$BUILT_INFO_PLIST" ]]; then
  echo "Built Info.plist not found at $BUILT_INFO_PLIST." >&2
  exit 1
fi
require_plist_value "$BUILT_INFO_PLIST" \
  "Print :UIBackgroundModes:0" \
  "remote-notification"

xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:"Writers BlockTests/TrashLifecycleTests"

echo "iOS CloudKit readiness passed: container, entitlements, remote notifications, build, and trash conflict tests are valid."
