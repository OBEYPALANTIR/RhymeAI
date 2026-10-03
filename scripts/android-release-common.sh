#!/usr/bin/env bash

require_empty_android_target() {
  if [[ ! "${ANDROID_SERIAL:-}" =~ ^emulator-[0-9]+$ ]]; then
    echo "Set ANDROID_SERIAL to an explicitly selected disposable emulator with no Writers Block installation." >&2
    return 1
  fi
  local state qemu
  state="$("$ADB" -s "$ANDROID_SERIAL" get-state | tr -d '\r')" || return 1
  qemu="$("$ADB" -s "$ANDROID_SERIAL" shell getprop ro.kernel.qemu | tr -d '\r')" || return 1
  if [[ "$state" != device || "$qemu" != 1 ]]; then
    echo "ANDROID_SERIAL must identify a running disposable emulator." >&2
    return 1
  fi
  local packages
  packages="$("$ADB" -s "$ANDROID_SERIAL" shell pm list packages com.rhymeai.app)" || return 1
  if [[ -n "$packages" ]]; then
    echo "Target already contains Writers Block packages. Use a new disposable emulator; existing apps and data will not be replaced." >&2
    return 1
  fi
}

verify_release_certificate() {
  local expected="${ANDROID_RELEASE_CERT_SHA256:-}"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]' | tr -d ':')"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Set ANDROID_RELEASE_CERT_SHA256 to the trusted release certificate SHA-256 fingerprint." >&2
    return 1
  fi
  local certificates actual
  certificates="$("$APKSIGNER" verify --print-certs "$1" 2>/dev/null)" || return 1
  actual="$(printf '%s\n' "$certificates" | sed -En 's/^(Signer #[0-9]+|V[0-9.]+ Signer:) certificate SHA-256 digest: ([[:xdigit:]]{64})$/\2/p' | tr '[:upper:]' '[:lower:]' | sort -u)"
  if [[ "$actual" != "$expected" ]]; then
    echo "APK signing certificate does not match the expected release certificate." >&2
    return 1
  fi
  echo "APK signature verified against the expected release certificate."
}

android_app_build_directory() {
  local directory
  directory="$(
    cd "$ANDROID_DIR" || return 1
    ./gradlew --no-daemon --quiet --console=plain :app:properties --property buildDir |
      sed -n 's/^buildDir: //p'
  )" || return 1
  if [[ "$directory" != /* || "$directory" == *$'\n'* ]]; then
    echo "Gradle did not report one absolute app build directory." >&2
    return 1
  fi
  printf '%s\n' "$directory"
}

android_build_tools_directory() {
  python3 - "$ANDROID_HOME/build-tools" <<'PYTOOLS'
from pathlib import Path
import re,sys
root=Path(sys.argv[1])
versions=[p for p in root.iterdir() if p.is_dir() and re.fullmatch(r"[0-9]+(?:\.[0-9]+)*",p.name) and (p/"apksigner").is_file() and (p/"aapt2").is_file()]
if not versions: sys.exit("No complete stable Android build-tools installation found.")
print(max(versions,key=lambda p:tuple(map(int,p.name.split(".")))))
PYTOOLS
}

capture_android_visual_state() {
  original_font_scale="$("$ADB" -s "$ANDROID_SERIAL" shell settings get system font_scale | tr -d '\r')" || return 1
  if [[ "$original_font_scale" != null && ! "$original_font_scale" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Cannot determine original font scale." >&2; return 1
  fi
  original_night_mode="$("$ADB" -s "$ANDROID_SERIAL" shell cmd uimode night | sed -n 's/^Night mode: //p' | tr -d '\r')" || return 1
  case "$original_night_mode" in auto|yes|no|custom) ;; *) echo "Cannot determine original night mode." >&2; return 1 ;; esac
}

restore_android_visual_state() {
  local failed=0
  if [[ "$original_font_scale" == null ]]; then
    "$ADB" -s "$ANDROID_SERIAL" shell settings delete system font_scale >/dev/null || failed=1
  else
    "$ADB" -s "$ANDROID_SERIAL" shell settings put system font_scale "$original_font_scale" >/dev/null || failed=1
  fi
  "$ADB" -s "$ANDROID_SERIAL" shell cmd uimode night "$original_night_mode" >/dev/null || failed=1
  if [[ "$failed" == 1 ]]; then echo "Failed to restore original Android visual settings." >&2; return 1; fi
}

install_release_apk() {
  require_empty_android_target || return 1
  APKSIGNER="$(android_build_tools_directory)/apksigner"
  verify_release_certificate "$1" || return 1
  python3 "$ROOT_DIR/scripts/scan-release-content.py" "$1" || return 1
  "$ADB" -s "$ANDROID_SERIAL" install "$1"
}
