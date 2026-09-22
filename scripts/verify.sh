#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
IOS_PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
IOS_SCHEME="${IOS_SCHEME:-Writers Block}"
source "$ROOT_DIR/scripts/ios-release-safety.sh"

if [[ "${SKIP_IOS:-0}" == "1" && "${SKIP_ANDROID:-0}" == "1" ]]; then
  echo "Both platforms are skipped; no verification was performed." >&2
  exit 2
fi

if [[ "${SKIP_IOS:-0}" != "1" ]]; then
  SIMULATOR_ID="${IOS_SIMULATOR_ID:-}"
  require_simulator_id IOS_SIMULATOR_ID "$SIMULATOR_ID"
  validate_simulator "$SIMULATOR_ID" iPhone
  require_uninstalled_app "$SIMULATOR_ID" "ShaydeTree.Writers-Block"
  IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi

if [[ -z "${JAVA_HOME:-}" && -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi

run_android() {
  echo "== Android: assembleDebug testDebugUnitTest lintDebug =="
  (
    cd "$ANDROID_DIR"
    ./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
  )
}

run_ios() {
  local work_dir
  work_dir="$(create_work_directory "" rhymeai-verify-ios)"
  echo "iOS verification work directory: $work_dir"
  echo "== iOS: build =="
  xcodebuild build \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -destination "$IOS_DESTINATION" \
    -derivedDataPath "$work_dir/DerivedData"

  echo "== iOS: Writers BlockTests =="
  validate_simulator "$SIMULATOR_ID" iPhone
  require_uninstalled_app "$SIMULATOR_ID" "ShaydeTree.Writers-Block"
  xcodebuild test \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -destination "$IOS_DESTINATION" \
    -derivedDataPath "$work_dir/DerivedData" \
    -parallel-testing-enabled NO \
    -only-testing:"Writers BlockTests"
}

if [[ "${SKIP_ANDROID:-0}" != "1" ]]; then
  run_android
fi

if [[ "${SKIP_IOS:-0}" != "1" ]]; then
  run_ios
fi

echo "Selected-platform verification complete (SKIP_IOS=${SKIP_IOS:-0}, SKIP_ANDROID=${SKIP_ANDROID:-0})."
