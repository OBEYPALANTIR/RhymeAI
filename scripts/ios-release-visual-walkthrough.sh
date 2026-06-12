#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
SCHEME="${IOS_SCHEME:-Writers Block}"
DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUTPUT_DIR="${IOS_RELEASE_VISUAL_WALKTHROUGH_OUTPUT_DIR:-$ROOT_DIR/artifacts/ios-release-visual-walkthrough/$RUN_ID}"
DERIVED_DATA="${IOS_RELEASE_VISUAL_WALKTHROUGH_DERIVED_DATA:-${TMPDIR:-/tmp}/rhymeai-ios-release-visual-walkthrough/$RUN_ID/DerivedData}"
RESULT_BUNDLE="$OUTPUT_DIR/WritersBlockReleaseVisualWalkthrough.xcresult"
ATTACHMENTS_DIR="$OUTPUT_DIR/attachments"
REPORT="$OUTPUT_DIR/report.txt"

rm -rf "$OUTPUT_DIR" "$DERIVED_DATA"
mkdir -p "$OUTPUT_DIR" "$ATTACHMENTS_DIR" "$(dirname "$DERIVED_DATA")"

xattr -rc "$ROOT_DIR/Writers Block/Writers Block" 2>/dev/null || true

xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
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

echo "iOS Release visual walkthrough passed."
echo "Report: $REPORT"
