# Writers Block

Writers Block is the native RhymeAI songwriting assistant for writing lyrics, managing songs, analyzing rhyme context, counting syllables, previewing stress/IPA, and generating AI rewrite suggestions.

The active targets are:

- Android: `android/`
- iOS: `Writers Block/`
- Desktop: planned

The old React/Vite web variant has been removed. Shared pronunciation/prosody data stays in `shared/`, with generation tooling in `scripts/`, because Android and iOS both consume those assets.

## Local verification

Run the default local gate from `/Users/tylermanring/Documents/RhymeAI`:

```sh
./scripts/verify.sh
```

The script runs Android `assembleDebug`, `testDebugUnitTest`, and `lintDebug`,
then builds iOS and runs `Writers BlockTests` against `iPhone 17 Pro, OS 26.5`.
Override the simulator with `IOS_DESTINATION`, or use `SKIP_ANDROID=1` /
`SKIP_IOS=1` for targeted runs.

To check final production sign-off status without printing secrets:

```sh
./scripts/final-signoff-status.sh
```

The status script verifies tracked key hygiene and required release docs, then
reports the remaining live gates. Set `RUN_VERIFY=1`, `RUN_PROVIDER_LIVE=1`,
`RUN_LOCAL_GGUF=1`, or `RUN_CLOUDKIT_READINESS=1` to execute the matching gates
when the required external keys, model file, devices, or account state exist.
The latest sign-off evidence is tracked in
`docs/FINAL_SIGNOFF_STATUS.md`.

## Features

- Section-aware suggestions and rewrites for `[Verse]`, `[Chorus]`, and `[Bridge]`.
- Streaming AI suggestions for Gemini, OpenAI, and Claude on Android and iOS.
- Trash Bin workflows with 30-day retention, restore, and permanent delete.
- Stress and IPA previews backed by shared CMU pronunciation assets.
- Native safe-area-aware editor controls for gesture bars, keyboards, and bottom sheets.

## Android

Run from `/Users/tylermanring/Documents/RhymeAI/android`:

```sh
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
./gradlew :app:lintDebug
./gradlew :app:connectedDebugAndroidTest
```

Release builds are minified. To produce signed release artifacts, create a gitignored
`android/keystore.properties`:

```properties
storeFile=/absolute/path/to/release.jks
storePassword=...
keyAlias=...
keyPassword=...
```

Then run:

```sh
./gradlew :app:assembleRelease
./gradlew :app:bundleRelease
```

Without `keystore.properties`, Gradle still builds the minified release APK/AAB for
R8 verification, but the APK output is unsigned. To run the release gate from the
repo root:

```sh
./scripts/android-release-smoke.sh
```

The release-smoke script builds the minified APK/AAB, verifies APK signing, scans
both release artifacts for the Gemini key pattern, and installs/launches the APK
when an `adb` device is attached. Set `REQUIRE_DEVICE=1` to fail when no emulator
or device is available, or `SKIP_INSTALL=1` for artifact-only verification.

To run the Android Release walkthrough gate on an attached emulator/device:

```sh
./scripts/android-release-walkthrough.sh
```

The walkthrough builds and key-scans the minified release artifacts, installs the
release APK, then drives create, save, graceful no-key suggestion handling,
export surface reachability, force-stop/reopen, and persisted lyrics through
the user-visible UI.

To run the Android Release live Gemini gate on an attached emulator/device:

```sh
./scripts/android-release-live-gemini.sh
```

The live gate reads `GEMINI_TEST_KEY` or gitignored `android/local.properties`
`geminiTestKey`, enters it through the release app Settings UI, then exercises
live Gemini suggestion and rewrite preview paths on the minified release APK.

To run the cross-platform OpenAI and Claude provider live smoke from the repo root:

```sh
read -rsp "OpenAI test key: " OPENAI_TEST_KEY; echo
read -rsp "Claude or Anthropic test key: " CLAUDE_TEST_KEY; echo
export OPENAI_TEST_KEY CLAUDE_TEST_KEY
./scripts/provider-live-smoke.sh
```

The provider live smoke runs Android and iOS service gates against the first
configured OpenAI and Claude models, verifying suggestions, rewrites, and
streaming without printing keys. `ANTHROPIC_TEST_KEY` may be used instead of
`CLAUDE_TEST_KEY`; set `OPENAI_TEST_MODEL` or `CLAUDE_TEST_MODEL` to override
the first configured provider model, and `SKIP_ANDROID=1` or `SKIP_IOS=1` for a
platform-only run.

To capture the Android Release visual audit on an attached emulator/device, or
the first available AVD when no device is attached:

```sh
./scripts/android-release-visual-audit.sh
```

The audit builds and key-scans the minified release artifacts, installs the
release APK, classifies the attached target as phone or tablet from its actual
screen size and density, captures launch screenshots in light, dark, and 1.3
font scale profiles, then captures populated editor, assistant panel, and export
sheet screenshots without entering an API key. Screenshots and a report are
written under `artifacts/android-release-visual-audit/`. Use `ANDROID_SERIAL` or
`ANDROID_AVD_NAME` to point the audit at a specific phone or tablet target.

To run the Android local GGUF inference smoke, attach an emulator or device and
provide a real model file:

```sh
LOCAL_GGUF_PATH=/absolute/path/to/model.gguf ./scripts/android-local-model-smoke.sh
```

The script verifies the GGUF header, builds and installs the debug app plus
instrumented test APK, pushes the model to `/data/local/tmp/`, and runs
`LocalModelInstrumentedTest` to prove the model loads and returns generated text.

## iOS

Use Xcode with:

```sh
Writers Block/Writers Block.xcodeproj
```

Or inspect schemes and destinations from the repo root:

```sh
xcodebuild -list -project "Writers Block/Writers Block.xcodeproj"
xcrun simctl list devices
```

Then build or test with the confirmed scheme and simulator destination.

To run the iOS Release gate from the repo root:

```sh
./scripts/ios-release-smoke.sh
```

The script builds a signed Release simulator app, scans the compiled binary for
the Gemini key pattern, installs/launches it on the default iPhone 17 Pro OS 26.5
simulator when available, then produces a signed generic iOS archive and scans
the archive binary. Build and archive output defaults to a temporary directory
outside the iCloud-synced repo; override with `IOS_RELEASE_WORK_DIR`,
`IOS_ARCHIVE_PATH`, or `SKIP_ARCHIVE=1` for targeted checks.

To run the iOS Release walkthrough gate:

```sh
./scripts/ios-release-walkthrough.sh
```

The walkthrough builds and tests the app in Release configuration, then verifies
song creation, save, export surface reachability, graceful no-key AI/rewrite
handling, and relaunch persistence.

To capture the iOS Release visual walkthrough:

```sh
./scripts/ios-release-visual-walkthrough.sh
```

The visual walkthrough builds and tests the app in Release configuration on the
default iPhone 17 Pro OS 26.5 simulator, then exports kept XCTest screenshots for
welcome, populated editor plus keyboard/UnBlock placement, export sheet,
assistant panel, graceful no-key assistant error, and graceful no-key rewrite
error states under `artifacts/ios-release-visual-walkthrough/`.

To capture the iOS Release light/dark phone/iPad screenshot audit:

```sh
./scripts/ios-release-visual-audit.sh
```

The audit builds the signed Release simulator app from a temporary directory,
installs it on iPhone 17 Pro and iPad Pro 13-inch OS 26.5 simulators in light
and dark appearance, verifies the process stays alive, and writes screenshots
under `artifacts/ios-release-visual-audit/` for human review.

To verify CloudKit readiness before the live two-device sync matrix:

```sh
./scripts/ios-cloudkit-readiness.sh
```

Then use `/Users/tylermanring/Documents/RhymeAI/docs/CLOUDKIT_SYNC_CHECKLIST.md`
for the iCloud-signed-in simulator/device matrix.

To verify iOS Local provider behavior on a simulator/device:

```sh
./scripts/ios-local-provider-smoke.sh
```

The smoke passes when Apple Foundation Models either return non-empty suggestions
or report a user-facing on-device availability reason.
