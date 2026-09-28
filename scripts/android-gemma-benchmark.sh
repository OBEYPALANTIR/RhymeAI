#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
source "$ROOT_DIR/scripts/android-release-common.sh"
MODEL_DIR="${GEMMA_MODEL_DIR:-$ROOT_DIR/artifacts/gemma-local-models}"
ARTIFACT_DIR="${GEMMA_BENCHMARK_DIR:-$ROOT_DIR/artifacts/gemma-benchmarks/$(date +%Y%m%d-%H%M%S)}"
if [[ "$ARTIFACT_DIR" != /* ]]; then
  ARTIFACT_DIR="$ROOT_DIR/$ARTIFACT_DIR"
fi

if [[ -n "${GEMMA_WIPE_AVD:-}" || -n "${ANDROID_AVD_NAME:-}" ||
      -n "${EMULATOR_MEMORY_MB:-}" || -n "${EMULATOR_PARTITION_SIZE_MB:-}" ]]; then
  echo "The benchmark does not boot or wipe an AVD. Start an empty disposable emulator yourself and set ANDROID_SERIAL." >&2
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

require_empty_android_target
serial="$ANDROID_SERIAL"

model_paths=("$@")
if [[ ${#model_paths[@]} -eq 0 ]]; then
  model_paths=(
    "$MODEL_DIR/gemma-4-E2B-it-UD-Q4_K_XL.gguf"
    "$MODEL_DIR/gemma-4-E4B-it-UD-Q4_K_XL.gguf"
  )
fi
for i in "${!model_paths[@]}"; do
  if [[ "${model_paths[$i]}" != /* ]]; then
    model_paths[$i]="$ROOT_DIR/${model_paths[$i]}"
  fi
  if [[ ! -r "${model_paths[$i]}" ||
        "$(LC_ALL=C head -c 4 "${model_paths[$i]}" 2>/dev/null)" != "GGUF" ]]; then
    echo "Model is missing, unreadable, or has no GGUF header: ${model_paths[$i]}" >&2
    exit 1
  fi
done

if [[ -e "$ARTIFACT_DIR" ]]; then
  echo "Benchmark output already exists; choose a new GEMMA_BENCHMARK_DIR: $ARTIFACT_DIR" >&2
  exit 1
fi
mkdir -p "$(dirname "$ARTIFACT_DIR")"
mkdir "$ARTIFACT_DIR"
cd "$ANDROID_DIR"
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest
APP_BUILD_DIR="$(android_app_build_directory)"

require_empty_android_target
"$ADB" -s "$serial" install "$APP_BUILD_DIR/outputs/apk/debug/app-debug.apk"
"$ADB" -s "$serial" install "$APP_BUILD_DIR/outputs/apk/androidTest/debug/app-debug-androidTest.apk"

device_model_path=""
logcat_pid=""
cleanup() {
  if [[ -n "$logcat_pid" ]]; then
    kill "$logcat_pid" >/dev/null 2>&1 || true
    wait "$logcat_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$device_model_path" ]]; then
    "$ADB" -s "$serial" shell rm -f "$device_model_path" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for i in "${!model_paths[@]}"; do
  host_model_path="${model_paths[$i]}"
  model_file="$(basename "$host_model_path")"
  model_label="${model_file%.gguf}"
  model_artifact_dir="$ARTIFACT_DIR/$(printf '%02d' "$((i + 1))")"
  mkdir "$model_artifact_dir"
  allocated_model_path="$("$ADB" -s "$serial" shell mktemp /data/local/tmp/rhymeai-model.XXXXXX | tr -d '\r')"
  if [[ ! "$allocated_model_path" =~ ^/data/local/tmp/rhymeai-model\.[[:alnum:]]+$ ]]; then
    echo "Could not allocate a fresh device model path." >&2
    exit 1
  fi
  device_model_path="$allocated_model_path"
  output_file="$model_artifact_dir/$model_label.txt"
  logcat_file="$model_artifact_dir/$model_label-logcat.txt"

  "$ADB" -s "$serial" shell df -h /data /data/local/tmp | tee "$model_artifact_dir/$model_label-df-before.txt"
  "$ADB" -s "$serial" push "$host_model_path" "$device_model_path"
  "$ADB" -s "$serial" shell chmod 644 "$device_model_path"
  "$ADB" -s "$serial" shell df -h /data /data/local/tmp | tee "$model_artifact_dir/$model_label-df-after-push.txt"

  echo "Running Gemma benchmark for $model_label on $serial"
  "$ADB" -s "$serial" logcat > "$logcat_file" 2>&1 &
  logcat_pid=$!
  set +e
  instrumentation_output="$("$ADB" -s "$serial" shell am instrument -w \
    -e class com.rhymeai.app.LocalModelInstrumentedTest \
    -e localModelPath "$device_model_path" \
    -e localModelLabel "$model_label" \
    com.rhymeai.app.test/androidx.test.runner.AndroidJUnitRunner 2>&1)"
  instrumentation_status=$?
  set -e
  kill "$logcat_pid" >/dev/null 2>&1 || true
  wait "$logcat_pid" >/dev/null 2>&1 || true
  logcat_pid=""
  printf '%s\n' "$instrumentation_output" | tee "$output_file"

  "$ADB" -s "$serial" shell rm -f "$device_model_path" >/dev/null 2>&1 || true
  device_model_path=""

  if [[ $instrumentation_status -ne 0 || "$instrumentation_output" == *"FAILURES!!!"* || "$instrumentation_output" != *"OK ("* ]]; then
    echo "Gemma benchmark failed for $model_label. Output saved to $output_file" >&2
    echo "Logcat saved to $logcat_file" >&2
    exit 1
  fi
done

echo "Gemma benchmark outputs saved under $ARTIFACT_DIR"
