# Android release live Gemini verification research

Date: 2026-06-02  
Scope: signed/minified Android release APK live Gemini Suggest Next Line and Rephrase/inline rewrite paths.

## Findings

- The release build is the right target: `android/app/build.gradle.kts` enables release minification and explicitly sets release `BuildConfig.GEMINI_TEST_KEY` to `""`, while debug reads `geminiTestKey` from gitignored `android/local.properties`. `MainViewModel.apiKey()` only uses `BuildConfig.GEMINI_TEST_KEY` when `BuildConfig.DEBUG` is true, so a release APK must use runtime Settings storage.
- Runtime key entry maps to the real app path. `SettingsDialog` edits the Gemini key field and `Save Settings` calls `MainViewModel.saveApiKey()`, which persists via `ProjectRepository.saveApiKey()` into `EncryptedPrefsKeyStore` / `EncryptedSharedPreferences`.
- The existing deterministic no-key gate is `scripts/android-release-walkthrough.sh`. It builds/key-scans via `scripts/android-release-smoke.sh`, clears app data, installs the release APK, creates lyrics, taps `Suggest Next Line`, and expects `No API key set`. Keep this script unchanged so no-key release behavior remains deterministic even after a live Gemini gate exists.
- A concurrent untracked script now exists at `scripts/android-release-live-gemini.sh`. It already follows the best overall shape: read `GEMINI_TEST_KEY` or `android/local.properties` `geminiTestKey`, build/sign/scan release artifacts through `android-release-smoke.sh`, install the release APK, clear app data, enter the key through Settings, exercise `Suggest Next Line`, then long-press lyrics and tap `Rephrase`.
- Existing unit coverage verifies Gemini service paths with the debug BuildConfig key in `android/app/src/test/kotlin/com/rhymeai/app/service/GeminiSdkLiveGateTest.kt`, including suggestion, rewrite, streaming, cancellation, and invalid-key non-leakage. That does not prove release runtime-key wiring, but it is useful as a lower-level provider gate.
- Existing Compose instrumentation tests in `android/app/src/androidTest/kotlin/com/rhymeai/app/NewFeatureUiTest.kt` cover assistant and rewrite UI behavior with test tags, but they are not the best release gate because instrumentation against a non-debuggable signed release APK is more signing/config fragile than an external `adb`/`uiautomator` walkthrough.

## Recommended script shape

Create or harden a separate root script, not a mode inside `android-release-walkthrough.sh`:

1. Resolve `JAVA_HOME`, `ANDROID_HOME`, `adb`, attached serial, and latest build-tools exactly like the existing Android release scripts.
2. Read the key from `GEMINI_TEST_KEY`; if missing, read `geminiTestKey` from gitignored `android/local.properties`. Do not print the key.
3. Run `SKIP_INSTALL=1 ./scripts/android-release-smoke.sh` to build the minified release APK/AAB, verify signing, and run the existing key-pattern scan.
4. Add a stronger artifact leak scan before install: unzip the APK and AAB into a temp dir and scan uncompressed contents for both the Gemini API-key prefix and the exact runtime key with `rg -a -F "$gemini_key"`; clean the temp dir on exit.
5. Uninstall/install the release APK, `pm clear com.rhymeai.app`, clear logcat, and start `com.rhymeai.app/.MainActivity`.
6. Use `uiautomator dump` plus text/content-desc matching for normal controls: `New Song`, `Settings`, `Paste your API key here...`, `Save Settings`, `UnBlock`, `Suggest Next Line`, `AI-generated`, `Rephrase`, `Previewing Rephrase`.
7. Enter the key only through Settings UI, save, and close Settings before any timeout dump that might include the focused password field.
8. Exercise suggestion success by waiting for the suggestions caveat/header (`AI-generated` / `Suggestions`) and preferably a non-empty suggestion card.
9. Exercise rewrite success by selecting any lyric text, tapping `Rephrase`, and waiting for `Previewing Rephrase` or the `Apply` button. In current code, loading text is `Rephrase...`; `Previewing Rephrase` appears only when `rewritePreview != null`, so it is a valid live-return marker.
10. Assert process alive and scan recent logcat for crash markers. Also scan recent logcat for the exact key and fail if present.

## UI automation hazards

- `adb shell input text` is acceptable for a Gemini key if it contains only the expected API-key characters, but the script should validate/escape conservatively. If the key ever contains shell-sensitive characters, input can corrupt it.
- Timeout dumps while the Settings key field is focused may leak the key if Compose/UiAutomator exposes editable text despite password transformation. Avoid dumping raw Settings XML after key entry, or redact the Gemini API-key prefix pattern and the exact key before stderr.
- `Settings` exists as both an icon content description and dialog title. It is safe before the dialog opens, but post-open matching should use `AI Provider`, `Save Settings`, or `Close`.
- `Suggest Next Line` is inside the assistant sheet scroll area; reuse the existing `wait_for_node_with_scroll` pattern.
- Rewrite selection is the fragile part. Shell `input` cannot set Compose `TextFieldValue.selection` like the existing Compose test can. Long-pressing visible lyric text is the practical route, but the script should fall back to long-pressing lyrics-editor bounds or retrying after keyboard dismissal if `Rephrase` does not appear.
- Do not click `Apply` unless the test lyrics are disposable and the script verifies expected mutation. For release smoke, proving `Previewing Rephrase`/`Apply` appears is enough to prove live rewrite returned without changing persisted lyrics.

## Likely verification commands

From `/Users/tylermanring/Documents/RhymeAI`:

```sh
./scripts/android-release-walkthrough.sh
GEMINI_TEST_KEY="$GEMINI_TEST_KEY" ./scripts/android-release-live-gemini.sh
```

Useful supporting checks:

```sh
cd /Users/tylermanring/Documents/RhymeAI/android
./gradlew :app:assembleRelease :app:bundleRelease
apksigner verify --print-certs app/build/outputs/apk/release/app-release.apk
```

Artifact leakage scan shape:

```sh
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
unzip -oqq android/app/build/outputs/apk/release/app-release.apk -d "$tmpdir/apk"
unzip -oqq android/app/build/outputs/bundle/release/app-release.aab -d "$tmpdir/aab"
gemini_prefix_pattern='AI''za[[:alnum:]_-]+'
rg -a "$gemini_prefix_pattern" "$tmpdir" && exit 1 || true
rg -a -F "$GEMINI_TEST_KEY" "$tmpdir" && exit 1 || true
```

## Recommendation

Use the external `adb`/`uiautomator` release walkthrough approach. It is the most practical fit for a non-debuggable signed/minified APK and directly verifies the user-visible runtime Settings path. Keep the no-key walkthrough separate and deterministic. Harden the live script around redaction, unzipped artifact scans, logcat exact-key scans, and rewrite-selection retries; do not move this into debug/instrumented tests or add app-only test hooks for release verification.
