#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
SCHEME="${IOS_SCHEME:-Writers Block}"
DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
DERIVED_DATA="${IOS_RELEASE_WALKTHROUGH_DERIVED_DATA:-${TMPDIR:-/tmp}/rhymeai-ios-release-walkthrough/DerivedData}"

rm -rf "$DERIVED_DATA"
xattr -rc "$ROOT_DIR/Writers Block/Writers Block" 2>/dev/null || true

xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  ENABLE_TESTABILITY=YES \
  -skip-testing:"Writers BlockTests" \
  -only-testing:"Writers BlockUITests/Writers_BlockUITests/testReleaseWalkthroughCreatesExportsAndPersistsSong" \
  -only-testing:"Writers BlockUITests/Writers_BlockUITests/testReleaseSuggestionNoKeyFailsGracefully" \
  -only-testing:"Writers BlockUITests/Writers_BlockUITests/testReleaseRewriteNoKeyFailsGracefully"

echo "iOS Release walkthrough passed: create, save, export surface, graceful no-key suggestion/rewrite, and relaunch persistence."
