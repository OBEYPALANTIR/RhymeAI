#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
source "$ROOT_DIR/scripts/android-release-common.sh"

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

latest_build_tools="$(android_build_tools_directory)"
APKSIGNER="$latest_build_tools/apksigner"
if [[ ! -x "$APKSIGNER" ]]; then
  echo "Could not find apksigner under $ANDROID_HOME/build-tools." >&2
  exit 1
fi

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  require_empty_android_target
fi
if [[ ! "${ANDROID_RELEASE_CERT_SHA256:-}" =~ ^([[:xdigit:]]{64}|([[:xdigit:]]{2}:){31}[[:xdigit:]]{2})$ ]]; then
  echo "Set ANDROID_RELEASE_CERT_SHA256 to the trusted release certificate SHA-256 fingerprint." >&2
  exit 1
fi

cd "$ANDROID_DIR"
./gradlew :app:assembleRelease :app:bundleRelease

APP_BUILD_DIR="$(android_app_build_directory)"
APK="$APP_BUILD_DIR/outputs/apk/release/app-release.apk"
AAB="$APP_BUILD_DIR/outputs/bundle/release/app-release.aab"

verify_release_certificate "$APK"
python3 "$ROOT_DIR/scripts/scan-release-content.py" "$APK" "$AAB"

if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
  echo "Skipping release install because SKIP_INSTALL=1."
  exit 0
fi

require_empty_android_target
serial="$ANDROID_SERIAL"

install_release_apk "$APK"
"$ADB" -s "$serial" shell am start -W -n com.rhymeai.app/.MainActivity
sleep 5

pid="$("$ADB" -s "$serial" shell pidof com.rhymeai.app | tr -d '\r' || true)"
if [[ -z "$pid" ]]; then
  "$ADB" -s "$serial" logcat -d -t 400 | rg -q 'FATAL EXCEPTION|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError' || true
  echo "Release app process did not stay alive after launch." >&2
  exit 1
fi

if "$ADB" -s "$serial" logcat -d -t 400 | rg -q 'FATAL EXCEPTION|ClassNotFoundException|NoSuchMethodError|UnsatisfiedLinkError'; then
  echo "Release launch emitted crash markers." >&2
  exit 1
fi

echo "Release APK installed and launched on $serial with pid $pid."
