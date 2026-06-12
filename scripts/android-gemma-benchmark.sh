#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
MODEL_DIR="${GEMMA_MODEL_DIR:-$ROOT_DIR/artifacts/gemma-local-models}"
ARTIFACT_DIR="${GEMMA_BENCHMARK_DIR:-$ROOT_DIR/artifacts/gemma-benchmarks/$(date +%Y%m%d-%H%M%S)}"

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
EMULATOR="$ANDROID_HOME/emulator/emulator"
if [[ ! -x "$ADB" ]]; then
  ADB="adb"
fi

wait_for_device() {
  local deadline=$((SECONDS + 180))
  while [[ $SECONDS -lt $deadline ]]; do
    local found
    found="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_boot_completed() {
  local serial="$1"
  local deadline=$((SECONDS + 240))
  while [[ $SECONDS -lt $deadline ]]; do
    local boot_completed
    boot_completed="$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$boot_completed" == "1" ]]; then
      "$ADB" -s "$serial" shell input keyevent 82 >/dev/null 2>&1 || true
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for Android boot completion on $serial." >&2
  return 1
}

serial="${ANDROID_SERIAL:-}"
if [[ -z "$serial" ]]; then
  serial="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi

if [[ -z "$serial" && -x "$EMULATOR" ]]; then
  avd_name="${ANDROID_AVD_NAME:-Medium_Phone_API_36.1}"
  echo "No adb device attached; booting AVD $avd_name"
  emulator_args=(-avd "$avd_name" -no-snapshot-load -no-boot-anim)
  if [[ -n "${EMULATOR_MEMORY_MB:-}" ]]; then
    emulator_args+=(-memory "$EMULATOR_MEMORY_MB")
  fi
  if [[ -n "${EMULATOR_PARTITION_SIZE_MB:-}" ]]; then
    emulator_args+=(-partition-size "$EMULATOR_PARTITION_SIZE_MB")
  fi
  if [[ -n "${GEMMA_WIPE_AVD:-}" ]]; then
    emulator_args+=(-wipe-data)
  fi
  "$EMULATOR" "${emulator_args[@]}" >/tmp/rhymeai-gemma-emulator.log 2>&1 &
  serial="$(wait_for_device || true)"
fi

if [[ -z "$serial" ]]; then
  echo "No adb device is attached for Gemma benchmark." >&2
  exit 1
fi

wait_for_boot_completed "$serial"

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
done

mkdir -p "$ARTIFACT_DIR"
cd "$ANDROID_DIR"
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest

"$ADB" -s "$serial" uninstall com.rhymeai.app >/dev/null 2>&1 || true
"$ADB" -s "$serial" uninstall com.rhymeai.app.test >/dev/null 2>&1 || true

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

install_apk app/build/outputs/apk/debug/app-debug.apk
install_apk app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk

for host_model_path in "${model_paths[@]}"; do
  if [[ ! -r "$host_model_path" ]]; then
    echo "Model is not readable: $host_model_path" >&2
    exit 1
  fi
  if [[ "$(LC_ALL=C head -c 4 "$host_model_path")" != "GGUF" ]]; then
    echo "Model does not start with a GGUF header: $host_model_path" >&2
    exit 1
  fi

  model_file="$(basename "$host_model_path")"
  model_label="${model_file%.gguf}"
  device_model_path="/data/local/tmp/rhymeai-$model_file"
  output_file="$ARTIFACT_DIR/$model_label.txt"
  logcat_file="$ARTIFACT_DIR/$model_label-logcat.txt"

  "$ADB" -s "$serial" shell rm -f "$device_model_path" >/dev/null 2>&1 || true
  "$ADB" -s "$serial" shell df -h /data /data/local/tmp | tee "$ARTIFACT_DIR/$model_label-df-before.txt"
  "$ADB" -s "$serial" push "$host_model_path" "$device_model_path"
  "$ADB" -s "$serial" shell df -h /data /data/local/tmp | tee "$ARTIFACT_DIR/$model_label-df-after-push.txt"

  echo "Running Gemma benchmark for $model_label on $serial"
  "$ADB" -s "$serial" logcat -c || true
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
  printf '%s\n' "$instrumentation_output" | tee "$output_file"

  "$ADB" -s "$serial" shell rm -f "$device_model_path" >/dev/null 2>&1 || true

  if [[ $instrumentation_status -ne 0 || "$instrumentation_output" == *"FAILURES!!!"* || "$instrumentation_output" != *"OK ("* ]]; then
    echo "Gemma benchmark failed for $model_label. Output saved to $output_file" >&2
    echo "Logcat saved to $logcat_file" >&2
    exit 1
  fi
done

echo "Gemma benchmark outputs saved under $ARTIFACT_DIR"
