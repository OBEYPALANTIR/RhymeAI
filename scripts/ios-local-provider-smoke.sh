#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
SCHEME="${IOS_SCHEME:-Writers Block}"
source "$ROOT_DIR/scripts/ios-release-safety.sh"
SIMULATOR_ID="${IOS_SIMULATOR_ID:-}"
require_simulator_id IOS_SIMULATOR_ID "$SIMULATOR_ID"
validate_simulator "$SIMULATOR_ID" iPhone
require_uninstalled_app "$SIMULATOR_ID" "ShaydeTree.Writers-Block"
DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
WORK_DIR="$(create_work_directory "" rhymeai-ios-local-provider)"
DERIVED_DATA="${IOS_LOCAL_PROVIDER_DERIVED_DATA:-$WORK_DIR/DerivedData}"
require_new_path "$DERIVED_DATA"
echo "iOS Local availability smoke work directory: $WORK_DIR"

xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$WORK_DIR/AvailabilitySmoke.xcresult" \
  -parallel-testing-enabled NO \
  -only-testing:"Writers BlockTests/LocalProviderSmokeTests/testLocalProviderReturnsTextOrAvailabilityMessage"

echo "Apple Foundation Models availability smoke passed; accepted GGUF load and inference remain separate required checks."
