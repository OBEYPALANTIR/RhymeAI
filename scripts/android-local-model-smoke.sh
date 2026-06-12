#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"

if [[ -z "${LOCAL_GGUF_PATH:-}" ]]; then
  echo "Set LOCAL_GGUF_PATH to a readable GGUF model file before running local inference smoke." >&2
  exit 1
fi

if [[ ! -r "$LOCAL_GGUF_PATH" ]]; then
  echo "LOCAL_GGUF_PATH is not readable: $LOCAL_GGUF_PATH" >&2
  exit 1
fi

if [[ "$(LC_ALL=C head -c 4 "$LOCAL_GGUF_PATH")" != "GGUF" ]]; then
  echo "LOCAL_GGUF_PATH does not start with a GGUF header: $LOCAL_GGUF_PATH" >&2
  exit 1
fi

if [[ -z "${JAVA_HOME:-}" && -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi

if [[ -z "${ANDROID_HOME:-}" ]]; then
  ANDROID_HOME="$(sed -n 's/^sdk.dir=//p' "$ANDROID_DIR/local.properties" 2>/dev/null || true)"
  export ANDROID_HOME
fi

if [[ -z "${ANDROID_HOME:-}" || ! -d "$ANDROID_HOME" ]]; then
  echo "ANDROID_HOME is not set and android/local.properties did not provide a valid sdk.dir." >&2
  exit 1
fi

ADB="$ANDROID_HOME/platform-tools/adb"
if [[ ! -x "$ADB" ]]; then
  ADB="adb"
fi

serial="${ANDROID_SERIAL:-}"
if [[ -z "$serial" ]]; then
  serial="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi

if [[ -z "$serial" ]]; then
  echo "No adb device is attached for local model smoke." >&2
  exit 1
fi

device_model_path="${DEVICE_GGUF_PATH:-/data/local/tmp/rhymeai-local-model-smoke.gguf}"

install_apk() {
  local apk="$1"
  local output
  if output="$("$ADB" -s "$serial" install -r "$apk" 2>&1)"; then
    printf '%s\n' "$output"
    return 0
  fi

  if [[ "$output" == *"INSTALL_FAILED_UPDATE_INCOMPATIBLE"* ]]; then
    echo "$output" >&2
    echo "Existing RhymeAI install has a different signature; uninstalling app/test packages and retrying." >&2
    "$ADB" -s "$serial" uninstall com.rhymeai.app >/dev/null 2>&1 || true
    "$ADB" -s "$serial" uninstall com.rhymeai.app.test >/dev/null 2>&1 || true
    "$ADB" -s "$serial" install -r "$apk"
    return 0
  fi

  echo "$output" >&2
  return 1
}

"$ADB" -s "$serial" shell rm -f "$device_model_path" >/dev/null 2>&1 || true

cd "$ANDROID_DIR"
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest

install_apk app/build/outputs/apk/debug/app-debug.apk
install_apk app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
"$ADB" -s "$serial" push "$LOCAL_GGUF_PATH" "$device_model_path"

instrumentation_output="$("$ADB" -s "$serial" shell am instrument -w \
  -e class com.rhymeai.app.LocalModelInstrumentedTest \
  -e localModelPath "$device_model_path" \
  com.rhymeai.app.test/androidx.test.runner.AndroidJUnitRunner 2>&1)"
printf '%s\n' "$instrumentation_output"

if [[ "$instrumentation_output" == *"FAILURES!!!"* || "$instrumentation_output" != *"OK ("* ]]; then
  echo "Android local GGUF instrumentation failed." >&2
  exit 1
fi

echo "Android local GGUF load and inference smoke passed on $serial."
