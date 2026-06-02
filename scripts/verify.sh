#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
IOS_PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
IOS_SCHEME="${IOS_SCHEME:-Writers Block}"
IOS_DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"

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
  echo "== iOS: build =="
  xcodebuild build \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -destination "$IOS_DESTINATION"

  echo "== iOS: Writers BlockTests =="
  xcodebuild test \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -destination "$IOS_DESTINATION" \
    -only-testing:"Writers BlockTests"
}

if [[ "${SKIP_ANDROID:-0}" != "1" ]]; then
  run_android
fi

if [[ "${SKIP_IOS:-0}" != "1" ]]; then
  run_ios
fi

echo "Verification complete."
