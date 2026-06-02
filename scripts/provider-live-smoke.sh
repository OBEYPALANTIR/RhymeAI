#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
IOS_PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
IOS_SCHEME="${IOS_SCHEME:-Writers Block}"
IOS_DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
IOS_DERIVED_DATA="${IOS_PROVIDER_LIVE_DERIVED_DATA:-${TMPDIR:-/tmp}/rhymeai-provider-live/DerivedData}"

if [[ -z "${OPENAI_TEST_KEY:-}" ]]; then
  echo "OPENAI_TEST_KEY is required for the OpenAI live smoke." >&2
  exit 2
fi

if [[ -z "${CLAUDE_TEST_KEY:-${ANTHROPIC_TEST_KEY:-}}" ]]; then
  echo "CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY is required for the Claude live smoke." >&2
  exit 2
fi

if [[ -z "${JAVA_HOME:-}" && -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi

if [[ "${SKIP_ANDROID:-0}" != "1" ]]; then
  echo "== Android: OpenAI/Claude provider live gates =="
  (
    cd "$ANDROID_DIR"
    ./gradlew :app:testDebugUnitTest --tests 'com.rhymeai.app.service.ProviderLiveGateTest'
  )
fi

if [[ "${SKIP_IOS:-0}" != "1" ]]; then
  echo "== iOS: OpenAI/Claude provider live gates =="
  rm -rf "$IOS_DERIVED_DATA"
  export SIMCTL_CHILD_OPENAI_TEST_KEY="$OPENAI_TEST_KEY"
  export SIMCTL_CHILD_CLAUDE_TEST_KEY="${CLAUDE_TEST_KEY:-}"
  export SIMCTL_CHILD_ANTHROPIC_TEST_KEY="${ANTHROPIC_TEST_KEY:-}"
  export SIMCTL_CHILD_OPENAI_TEST_MODEL="${OPENAI_TEST_MODEL:-}"
  export SIMCTL_CHILD_CLAUDE_TEST_MODEL="${CLAUDE_TEST_MODEL:-}"
  xcodebuild test \
    -project "$IOS_PROJECT" \
    -scheme "$IOS_SCHEME" \
    -destination "$IOS_DESTINATION" \
    -derivedDataPath "$IOS_DERIVED_DATA" \
    -only-testing:"Writers BlockTests/ProviderLiveSmokeTests"
fi

echo "OpenAI/Claude provider live smoke passed."
