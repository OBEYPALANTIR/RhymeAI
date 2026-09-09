#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
SCHEME="${IOS_SCHEME:-Writers Block}"
source "$ROOT_DIR/scripts/ios-release-safety.sh"
SIMULATOR_ID="${IOS_SIMULATOR_ID:-}"
require_simulator_id IOS_SIMULATOR_ID "$SIMULATOR_ID"
if [[ -n "${IOS_RELEASE_VISUAL_WALKTHROUGH_DERIVED_DATA:-}" ]]; then
  require_new_path "$IOS_RELEASE_VISUAL_WALKTHROUGH_DERIVED_DATA"
fi
if [[ -n "${IOS_RELEASE_VISUAL_WALKTHROUGH_OUTPUT_DIR:-}" ]]; then
  require_new_path "$IOS_RELEASE_VISUAL_WALKTHROUGH_OUTPUT_DIR"
fi
validate_simulator "$SIMULATOR_ID" iPhone
require_uninstalled_app "$SIMULATOR_ID" "ShaydeTree.Writers-Block"
DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
WORK_DIR="$(create_work_directory "" rhymeai-ios-release-visual-walkthrough)"
DERIVED_DATA="${IOS_RELEASE_VISUAL_WALKTHROUGH_DERIVED_DATA:-$WORK_DIR/DerivedData}"
require_new_path "$DERIVED_DATA"
mkdir -p "$(dirname "$DERIVED_DATA")"
if [[ -n "${IOS_RELEASE_VISUAL_WALKTHROUGH_OUTPUT_DIR:-}" ]]; then
  OUTPUT_DIR="$(create_work_directory "$IOS_RELEASE_VISUAL_WALKTHROUGH_OUTPUT_DIR" unused)"
else
  mkdir -p "$ROOT_DIR/artifacts/ios-release-visual-walkthrough"
  OUTPUT_DIR="$(mktemp -d "$ROOT_DIR/artifacts/ios-release-visual-walkthrough/$RUN_ID.XXXXXX")"
fi
RESULT_BUNDLE="$OUTPUT_DIR/WritersBlockReleaseVisualWalkthrough.xcresult"
ATTACHMENTS_DIR="$OUTPUT_DIR/attachments"
REPORT="$OUTPUT_DIR/report.txt"
mkdir "$ATTACHMENTS_DIR"

xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -parallel-testing-enabled NO \
  ENABLE_TESTABILITY=YES \
  -skip-testing:"Writers BlockTests" \
  -only-testing:"Writers BlockUITests/Writers_BlockUITests/testReleaseVisualWalkthroughCapturesScreenshots"

xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$ATTACHMENTS_DIR"

{
  echo "iOS Release visual walkthrough"
  echo "Run: $RUN_ID"
  echo "Destination: $DESTINATION"
  echo "Result bundle: $RESULT_BUNDLE"
  echo "Attachments: $ATTACHMENTS_DIR"
  echo
  find "$ATTACHMENTS_DIR" -type f | sort
} > "$REPORT"

echo "iOS Release visual walkthrough tests and attachment export completed; human visual review required."
echo "Report: $REPORT"
