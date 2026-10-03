#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/android-release-common.sh"
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
: "${JAVA_HOME:?Set JAVA_HOME to a JDK}"
if [[ ! -x "$JAVA_HOME/bin/keytool" ]]; then
  echo "JAVA_HOME must contain an executable bin/keytool." >&2; exit 1
fi
export PATH="$JAVA_HOME/bin:$PATH"
BUILD_TOOLS="$(android_build_tools_directory)"
APKSIGNER="$BUILD_TOOLS/apksigner"
AAPT2="$BUILD_TOOLS/aapt2"
work_dir="$(mktemp -d)"
trap 'rm -r "$work_dir"' EXIT
cat > "$work_dir/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.rhymeai.auditfixture" android:versionCode="1" android:versionName="1">
<uses-sdk android:minSdkVersion="26" android:targetSdkVersion="36"/>
<application android:label="Audit fixture"/>
</manifest>
XML
"$AAPT2" link -o "$work_dir/unsigned.apk" --manifest "$work_dir/AndroidManifest.xml" -I "$ANDROID_HOME/platforms/android-36/android.jar"
keytool -genkeypair -alias fixture -keyalg RSA -keysize 2048 -validity 1   -dname 'CN=Disposable Audit Fixture' -keystore "$work_dir/fixture.jks"   -storepass fixture-password -keypass fixture-password >/dev/null 2>&1
"$APKSIGNER" sign --ks "$work_dir/fixture.jks" --ks-pass pass:fixture-password   --out "$work_dir/signed.apk" "$work_dir/unsigned.apk"
keytool -exportcert -alias fixture -keystore "$work_dir/fixture.jks" -storepass fixture-password -file "$work_dir/certificate.der" >/dev/null 2>&1
ANDROID_RELEASE_CERT_SHA256="$(shasum -a 256 "$work_dir/certificate.der" | awk '{print $1}')"
export ANDROID_RELEASE_CERT_SHA256
verify_release_certificate "$work_dir/signed.apk"
ANDROID_RELEASE_CERT_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
if verify_release_certificate "$work_dir/signed.apk"; then
  echo "Wrong certificate was accepted." >&2; exit 1
fi
if verify_release_certificate "$work_dir/unsigned.apk"; then
  echo "Unsigned package was accepted." >&2; exit 1
fi
echo "Certificate regression passed: matching signer accepted, wrong signer and unsigned APK rejected."
