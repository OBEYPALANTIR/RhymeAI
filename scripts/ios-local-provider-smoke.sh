#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
SCHEME="${IOS_SCHEME:-Writers Block}"
DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
DERIVED_DATA="${IOS_LOCAL_PROVIDER_DERIVED_DATA:-${TMPDIR:-/tmp}/rhymeai-ios-local-provider/DerivedData}"

rm -rf "$DERIVED_DATA"
xattr -rc "$ROOT_DIR/Writers Block/Writers Block" 2>/dev/null || true

xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:"Writers BlockTests/LocalProviderSmokeTests/testLocalProviderReturnsTextOrAvailabilityMessage"

echo "iOS Local provider smoke passed: returned suggestions or surfaced an on-device availability message."
