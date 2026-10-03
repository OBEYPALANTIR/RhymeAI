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
then builds iOS and runs `Writers BlockTests`. Set `IOS_SIMULATOR_ID` to an
explicitly selected, already-booted disposable iPhone simulator without Writers
Block installed. Fresh build output is retained for inspection. Use
`SKIP_ANDROID=1` or `SKIP_IOS=1` for a targeted run; skipping both is an error.

To check final production sign-off status without printing secrets:

```sh
./scripts/final-signoff-status.sh
```

The script is a diagnostic, not final approval: it checks tracked key hygiene
and required release docs without printing matches, and always exits 2 while
reviewed installed-candidate, live, signing, and store evidence remains external.
Historical markdown and shell flags cannot establish current acceptance. Set `RUN_VERIFY=1`, `RUN_PROVIDER_LIVE=1`,
`RUN_LOCAL_GGUF=1`, or `RUN_CLOUDKIT_READINESS=1` to rerun the matching gates
when the required external keys, model file, devices, or account state exist.

To preflight only the remaining external live-gate prerequisites without printing
secrets:

```sh
./scripts/remaining-live-gates-preflight.sh
```

Set `CLOUDKIT_SIM_A` and `CLOUDKIT_SIM_B` to specific booted simulator UDIDs, or
leave them unset to use the first two booted iOS simulators.

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

When permanent song deletion cannot remove every recording, Android keeps a
pending cleanup record and reports that deletion is incomplete. It retries on
the next app launch or Trash purge. Recordings for pending deletions are omitted
from new local Drive uploads; Android Auto Backup retains the pending record with
any remaining files so cleanup resumes after restore.

Android now pairs the iOS v2 envelope version with RAI2 and emits the required
song, trash, and recording body keys even when their values equal defaults.
iOS reads that format but writes v3 under RAI3, which Android cannot read yet,
so a backup last written by iOS shows as unreadable on Android and is left
untouched. Native two-platform exchange has not been verified. On Android v2 sync,
tombstoned songs are hidden and their recordings are no longer uploaded or
advertised by the receiving device, even if an older copy is edited later.
An upload that precedes a newly arriving remote tombstone is not undone;
the refreshed decision prevents re-upload and final advertisement. Local audio
files and notebook data are retained pending a separate cleanup decision.
Android does not erase previously uploaded recording bytes from Drive; iOS
peers do erase remote bytes, so the two platforms currently differ there.

The v2 deletion regressions run in `:app:testDebugUnitTest`. Their test source
uses `SyncDeletion` and `SyncBlob.deletions`, so it does not compile unchanged
against the pre-v2 base `3a0e8971`; the table identifies the behavioral
assertion that base could not satisfy rather than claiming a base test run.

| Case | Regression test | Base behavior contradicted |
| --- | --- | --- |
| T-1 | `SyncMergerTest.permanentDeletionsConvergeAgainstNewerProjectTrashAndRecordingContent` | A newer stale project/trash/recording survives instead of the tombstone winning. |
| T-2 | `DriveSyncServiceTest.supportedV1AndV2RemoteShapesMergeIntoV2WithoutRestoringDeletedSong` and `unsupportedVersionShapesNeverBecomeRemoteOrReplaceLocalData` | A valid v2 blob is rejected; v1 with a deletion key is not rejected as a shape error. |
| T-3 | `ProjectRepositoryTest.permanentDeleteWritesTombstoneBeforeSyncAndSurvivesRepositoryReopen` | Reopen has no persisted project tombstone; a stale remote copy returns on merge. |
| T-4 | `ProjectRepositoryTest.expiryPurgeWritesTombstonesForBothSongsBeforeRemoteMerge` | Neither purged ID has a persisted tombstone; stale copies return on merge. |
| T-5 | `ProjectRepositoryTest.deletionCommittedAfterBaseReadSurvivesSyncApplyAndLaterUpload` | The later sync snapshot has no deletion marker for the post-base Delete Forever. |
| T-6 | `ProjectRepositoryTest.remoteProjectTombstoneRemovesPostSnapshotLocalSongAndRestorePlan` | A remote tombstone cannot suppress the local song and recording restore plan. |
| T-7 | `DriveSyncServiceTest.uploadOnlyWritesV2AndExplicitEmptyDeletionArrayEvenFromLegacyLocalBlob` | UploadOnly writes v1 without an explicit empty `deletions` array. |

The corrective tests below compare against the PR #60 base `3d1bca7c`
(source-level predictions, not a failing-before run). C-5 guards an unchanged
recording format and is intentionally expected to pass on both tips.

| Case | Regression test | PR #60 base assertion |
| --- | --- | --- |
| C-1 | `SyncBlobCryptoTest.v2ManifestUsesRai2WhileRecordingEncryptionRemainsRai1` | No RAI2 manifest writer/reader exists; current v2 seal uses RAI1. |
| C-2 | `SyncBlobCryptoTest.independentPythonVectorsOpenAndSealByteIdenticallyForBothEnvelopeVersions` | RAI2 reference envelope cannot open and deterministic RAI2 seal is absent. |
| C-3 | `DriveSyncServiceTest.envelopeVersionMismatchIsCorruptRemoteNotWrongPassphrase` and `SyncBlobCryptoTest.unknownAndTruncatedManifestHeadersAreDistinctFromAuthenticationFailure` | A version-2 body under RAI1 is accepted; RAI2/unknown magic is misclassified as a passphrase error. |
| C-4 | `SyncBlobCryptoTest.rai2HeaderBodyAndTagTamperingFailsClosed` | No RAI2 authenticated-header path exists. |
| C-5 | Existing `SyncBlobCryptoTest.deterministicSealMatchesSharedRAI1GoldenFixture` | Carry-forward guard: recording RAI1 bytes must not change; no base failure expected. |
| U-1/U-2 | `ReceivingDeviceUploadTest.firstAndRepeatedSyncDoNotReuploadRemotelyDeletedSongOrRemoveLocalBytes` | Uploads before apply send a remotely tombstoned recording on both passes. |
| U-3 | `ReceivingDeviceUploadTest.refreshedRemoteProjectTombstoneStopsSecondUploadAndFinalAdvertisement` | Post-refresh upload planning still sends the tombstoned recording. |
| U-4 | `ReceivingDeviceUploadTest.uploadOnlyWithWriteAheadDeleteAdvertisesNoRecordingAndRetainsPendingBytes` | A stale local manifest can still advertise a pending-deletion file through UploadOnly (including refreshed UploadOnly). |
| U-5 | `ReceivingDeviceUploadTest.remoteFileTombstoneExcludesOnlyNamedRecordingFromActualUpload` | The locally present named file is uploaded despite the remote file tombstone. |
| U-6 | `DriveSyncServiceTest.independentIosShapeVectorsUnderRai2AndLegacyRai1MergeCorrectly` | iOS-shaped RAI2 fails to decrypt while legacy RAI1 remains readable. |

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

CI or an explicit local build may instead supply the complete `RHYMEAI_KEYSTORE_FILE`,
`RHYMEAI_STORE_PASSWORD`, `RHYMEAI_KEY_ALIAS`, and `RHYMEAI_KEY_PASSWORD` tuple.
When any of those variables is present, that complete tuple takes precedence over
`keystore.properties`; partial environment signing material is rejected. Release
APK/AAB tasks fail before packaging when the selected signing material is incomplete
or unavailable, so Gradle does not emit an unsigned release fallback. To run the
release gate from the repo root:

```sh
./scripts/android-release-smoke.sh
```

Set `ANDROID_RELEASE_CERT_SHA256` to the trusted release certificate fingerprint
and `ANDROID_SERIAL` to an explicitly selected, already-running `emulator-NNNN`
target without Writers Block or its test package. The Android release walkthrough,
live Gemini, visual audit, local-model smoke, and Gemma benchmark scripts also
require an explicit empty emulator; they do not select, boot, wipe, or replace
a device automatically. The release smoke verifies the trusted APK signer and
scans decompressed APK/AAB entries before installation. `SKIP_INSTALL=1` performs
artifact-only checks without a target; it still requires the trusted fingerprint.
The scripts do not offer an upgrade or uninstall fallback.

To run the Android Release walkthrough gate on that empty emulator:

```sh
./scripts/android-release-walkthrough.sh
```

The walkthrough builds and key-scans the minified release artifacts, installs the
release APK, then drives create, save, graceful no-key suggestion handling,
export surface reachability, force-stop/reopen, and persisted lyrics through
the user-visible UI.

To run the Android Release live Gemini gate on that empty emulator:

```sh
./scripts/android-release-live-gemini.sh
```

The live gate reads `GEMINI_TEST_KEY` or gitignored `android/local.properties`
`geminiTestKey`, removes the environment key before release builds, and sends it
to the device over stdin for Settings entry. Exact-key artifact/log checks keep
the key out of host command arguments and diagnostics. The Android input utility
receives the value inside the explicitly selected test emulator. UI diagnostics
are withheld while a runtime key is in use.

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
platform-only run. Both skipped is rejected. iOS execution requires the same
`IOS_SIMULATOR_ID` guard and a fresh derived-data path; existing output is preserved.

To capture the Android Release visual audit on the explicitly selected empty emulator:

```sh
./scripts/android-release-visual-audit.sh
```

The audit builds and key-scans the minified release artifacts, installs the
release APK, classifies the attached target as phone or tablet from its actual
screen size and density, captures launch screenshots in light, dark, and 1.3
font scale profiles, then captures populated editor, assistant panel, and export
sheet screenshots without entering an API key. Screenshots and a report are
written under `artifacts/android-release-visual-audit/`. Existing output directories
are refused. Original font scale (including an unset value) and night mode are
restored on exit. Choose a phone or tablet with `ANDROID_SERIAL`.

To run Android local GGUF inference smoke, select an empty emulator with
`ANDROID_SERIAL` and provide a real model file:

```sh
LOCAL_GGUF_PATH=/absolute/path/to/model.gguf ./scripts/android-local-model-smoke.sh
```

The script verifies the GGUF header, builds and installs the debug app plus
instrumented test APK, pushes the model to `/data/local/tmp/`, and runs
`LocalModelInstrumentedTest` to prove the model loads and returns generated text.

To download and benchmark the recommended Android Gemma GGUF models:

```sh
./scripts/download-gemma-models.sh
ANDROID_SERIAL=emulator-5554 ./scripts/android-gemma-benchmark.sh
```

Start and explicitly select a disposable emulator with no Writers Block installation
and enough free space for each model before running the benchmark. It refuses an
existing installation and legacy AVD boot/wipe options. The benchmark runs the
local provider through raw generation, suggestions, rewrite, and synonyms, then
saves timing, disk, instrumentation, and logcat evidence in a numbered directory
per model under `artifacts/gemma-benchmarks/`, without replacing pre-existing
model files or another model's benchmark evidence.

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
the Gemini key pattern, installs/launches it only on a booted disposable iPhone selected with
`IOS_SIMULATOR_ID`, then produces a signed generic iOS archive and scans the
archive binary. Existing Writers Block installations are refused. Use
`SKIP_SIM_LAUNCH=1` for build-only work and `SKIP_ARCHIVE=1` to omit the archive.
Build and archive outputs use a fresh temporary directory. Explicit
`IOS_RELEASE_WORK_DIR`, `IOS_RELEASE_DERIVED_DATA`, and `IOS_ARCHIVE_PATH`
outputs must not already exist; previous artifacts are preserved.

To run the iOS Release walkthrough gate:

```sh
./scripts/ios-release-walkthrough.sh
```

The walkthrough requires a fresh, booted disposable iPhone selected by
`IOS_SIMULATOR_ID`. It builds and tests in Release configuration, exercising song
creation, save, export reachability, no-key AI/rewrite handling, and relaunch
persistence. Configured output paths must be new; existing files are preserved.

To capture the iOS Release visual walkthrough:

```sh
./scripts/ios-release-visual-walkthrough.sh
```

The visual walkthrough builds and tests in Release configuration on the fresh,
booted disposable iPhone selected by `IOS_SIMULATOR_ID`, then exports kept XCTest screenshots for
welcome, populated editor plus keyboard/UnBlock placement, export sheet,
assistant panel, graceful no-key assistant error, and graceful no-key rewrite
error states under `artifacts/ios-release-visual-walkthrough/`.

To capture the iOS Release light/dark phone/iPad screenshot audit:

```sh
./scripts/ios-release-visual-audit.sh
```

The audit requires `IOS_SIMULATOR_ID` and `IOS_IPAD_SIMULATOR_ID` to identify
booted, disposable phone and iPad simulators with no Writers Block installation.
It builds a Release simulator app, installs once per target, captures light and
dark appearances, and writes screenshots under `artifacts/ios-release-visual-audit/`
for human review. It does not erase, uninstall, or select an existing target by
name. `SKIP_BUILD=1` requires an explicit `IOS_VISUAL_AUDIT_DERIVED_DATA` path.

To verify CloudKit readiness before the live two-device sync matrix:

```sh
./scripts/ios-cloudkit-readiness.sh
```

Then use `/Users/tylermanring/Documents/RhymeAI/docs/CLOUDKIT_SYNC_CHECKLIST.md`
for the iCloud-signed-in simulator/device matrix.

To check Apple Foundation Models availability on a booted disposable iPhone simulator:

```sh
IOS_SIMULATOR_ID='<empty-disposable-iphone-udid>' ./scripts/ios-local-provider-smoke.sh
```

The smoke passes when Apple Foundation Models either return non-empty suggestions
or report a user-facing on-device availability reason. It preserves existing
installations and build outputs. This is an availability check; it does not
verify loading the accepted GGUF, local inference quality, or the in-app writing flow.
