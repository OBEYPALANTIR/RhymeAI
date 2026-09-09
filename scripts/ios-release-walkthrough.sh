#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
SCHEME="${IOS_SCHEME:-Writers Block}"
source "$ROOT_DIR/scripts/ios-release-safety.sh"
SIMULATOR_ID="${IOS_SIMULATOR_ID:-}"
require_simulator_id IOS_SIMULATOR_ID "$SIMULATOR_ID"
if [[ -n "${IOS_RELEASE_WALKTHROUGH_DERIVED_DATA:-}" ]]; then
  require_new_path "$IOS_RELEASE_WALKTHROUGH_DERIVED_DATA"
fi
validate_simulator "$SIMULATOR_ID" iPhone
require_uninstalled_app "$SIMULATOR_ID" "ShaydeTree.Writers-Block"
DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
WORK_DIR="$(create_work_directory "" rhymeai-ios-release-walkthrough)"
DERIVED_DATA="${IOS_RELEASE_WALKTHROUGH_DERIVED_DATA:-$WORK_DIR/DerivedData}"
require_new_path "$DERIVED_DATA"
mkdir -p "$(dirname "$DERIVED_DATA")"
echo "iOS Release walkthrough work directory: $WORK_DIR"

xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$WORK_DIR/Walkthrough.xcresult" \
  -parallel-testing-enabled NO \
  ENABLE_TESTABILITY=YES \
  -skip-testing:"Writers BlockTests" \
  -only-testing:"Writers BlockUITests/Writers_BlockUITests/testReleaseWalkthroughCreatesExportsAndPersistsSong" \
  -only-testing:"Writers BlockUITests/Writers_BlockUITests/testReleaseSuggestionNoKeyFailsGracefully" \
  -only-testing:"Writers BlockUITests/Writers_BlockUITests/testReleaseRewriteNoKeyFailsGracefully"

echo "iOS Release walkthrough passed: create, save, export surface, graceful no-key suggestion/rewrite, and relaunch persistence."
