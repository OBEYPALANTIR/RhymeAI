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

The script builds the Release simulator app, scans the compiled binary for the
Gemini key pattern, installs/launches it on the default iPhone 17 Pro OS 26.5
simulator when available, then produces a signed generic iOS archive and scans
the archive binary. Archive output defaults to a temporary directory outside the
iCloud-synced repo; override with `IOS_RELEASE_WORK_DIR`, `IOS_ARCHIVE_PATH`, or
`SKIP_ARCHIVE=1` for targeted checks.

To verify CloudKit readiness before the live two-device sync matrix:

```sh
./scripts/ios-cloudkit-readiness.sh
```

Then use `/Users/tylermanring/Documents/RhymeAI/docs/CLOUDKIT_SYNC_CHECKLIST.md`
for the iCloud-signed-in simulator/device matrix.
