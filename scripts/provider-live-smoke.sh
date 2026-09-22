#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
IOS_PROJECT="$ROOT_DIR/Writers Block/Writers Block.xcodeproj"
IOS_SCHEME="${IOS_SCHEME:-Writers Block}"
source "$ROOT_DIR/scripts/ios-release-safety.sh"

if [[ "${SKIP_IOS:-0}" == "1" && "${SKIP_ANDROID:-0}" == "1" ]]; then
  echo "Both platforms are skipped; no verification was performed." >&2
  exit 2
fi

if [[ -z "${OPENAI_TEST_KEY:-}" ]]; then
  echo "OPENAI_TEST_KEY is required for the OpenAI live smoke." >&2
  exit 2
fi

if [[ -z "${CLAUDE_TEST_KEY:-${ANTHROPIC_TEST_KEY:-}}" ]]; then
  echo "CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY is required for the Claude live smoke." >&2
  exit 2
fi

if [[ "${SKIP_IOS:-0}" != "1" ]]; then
  SIMULATOR_ID="${IOS_SIMULATOR_ID:-}"
  require_simulator_id IOS_SIMULATOR_ID "$SIMULATOR_ID"
  if [[ -n "${IOS_PROVIDER_LIVE_DERIVED_DATA:-}" ]]; then
    require_new_path "$IOS_PROVIDER_LIVE_DERIVED_DATA"
  fi
  validate_simulator "$SIMULATOR_ID" iPhone
  require_uninstalled_app "$SIMULATOR_ID" "ShaydeTree.Writers-Block"
  IOS_DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
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
  WORK_DIR="$(create_work_directory "" rhymeai-provider-live)"
  IOS_DERIVED_DATA="${IOS_PROVIDER_LIVE_DERIVED_DATA:-$WORK_DIR/DerivedData}"
  require_new_path "$IOS_DERIVED_DATA"
  mkdir -p "$(dirname "$IOS_DERIVED_DATA")"
  validate_simulator "$SIMULATOR_ID" iPhone
  require_uninstalled_app "$SIMULATOR_ID" "ShaydeTree.Writers-Block"
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
    -parallel-testing-enabled NO \
    -only-testing:"Writers BlockTests/ProviderLiveSmokeTests"
fi

echo "Selected-platform OpenAI/Claude live smoke passed (SKIP_IOS=${SKIP_IOS:-0}, SKIP_ANDROID=${SKIP_ANDROID:-0})."
