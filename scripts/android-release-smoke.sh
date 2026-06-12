#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"

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

latest_build_tools="$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
APKSIGNER="$latest_build_tools/apksigner"
if [[ ! -x "$APKSIGNER" ]]; then
  echo "Could not find apksigner under $ANDROID_HOME/build-tools." >&2
  exit 1
fi

cd "$ANDROID_DIR"
./gradlew :app:assembleRelease :app:bundleRelease

APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"
AAB="$ANDROID_DIR/app/build/outputs/bundle/release/app-release.aab"

"$APKSIGNER" verify --print-certs "$APK"

for artifact in "$APK" "$AAB"; do
  if strings "$artifact" | rg -q 'AI[z]a'; then
    echo "Release artifact contains a Gemini API key pattern: $artifact" >&2
    exit 1
  fi
done
echo "Release artifact key scan passed."

if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
  echo "Skipping release install because SKIP_INSTALL=1."
  exit 0
fi

serial="${ANDROID_SERIAL:-}"
if [[ -z "$serial" ]]; then
  serial="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi

if [[ -z "$serial" ]]; then
  if [[ "${REQUIRE_DEVICE:-0}" == "1" ]]; then
    echo "No adb device is attached for release install smoke." >&2
    exit 1
  fi
  echo "No adb device attached; release install smoke skipped."
  exit 0
fi

"$ADB" -s "$serial" uninstall com.rhymeai.app >/dev/null 2>&1 || true
"$ADB" -s "$serial" logcat -c
"$ADB" -s "$serial" install "$APK"
"$ADB" -s "$serial" shell am start -W -n com.rhymeai.app/.MainActivity
sleep 5

pid="$("$ADB" -s "$serial" shell pidof com.rhymeai.app | tr -d '\r' || true)"
if [[ -z "$pid" ]]; then
  "$ADB" -s "$serial" logcat -d -t 400 | rg -n 'FATAL EXCEPTION|AndroidRuntime|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError' || true
  echo "Release app process did not stay alive after launch." >&2
  exit 1
fi

if "$ADB" -s "$serial" logcat -d -t 400 | rg -n 'FATAL EXCEPTION|AndroidRuntime|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError'; then
  echo "Release launch emitted crash markers." >&2
  exit 1
fi

echo "Release APK installed and launched on $serial with pid $pid."
