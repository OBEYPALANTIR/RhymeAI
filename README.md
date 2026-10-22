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

Google Drive backup uses manifest v4: a plain UTF-8 JSON file
`rhymeai-manifest.json` in Drive's `appDataFolder` plus one raw
`rec_<projectId>_<fileName>` file per recording, with `projectId`, `fileName`,
`sha256` and `bytes` in Drive `appProperties`. There is no passphrase.
`manifestSha256` covers the canonical form of the manifest (keys sorted by code
point, no whitespace, only `\"`, `\\`, `\n`, `\r`, `\t` and lowercase `\u00xx`
escapes, integers only); a reader refuses a manifest whose hash does not match
("Backup file is damaged; it was not merged.") or whose `version` is above 4,
and never overwrites it. Each recording entry carries `uploadedAt` (ISO-8601
UTC). `shared/fixtures/sync-manifest-v4.json`, written by
`python3 scripts/generate-sync-manifest-v4-fixture.py` (stdlib only; `--check`
fails when the file is stale), pins the canonical string and hash. iOS tests
read a copy at `Writers Block/Writers BlockTests/sync-manifest-v4.json`;
`BackupManifestTest` fails if that copy drifts and skips while it is absent.
The iOS side of v4 is pending its companion PR.

Back up now and the automatic backup merge this device into Drive and never
change local data. The automatic backup runs 30 seconds after the last change
to songs, trash, tombstones or recordings while Drive is connected, and when the
app goes to the background (at most every 15 minutes unless a backup is
pending); recordings added by Import trigger it too; runs never overlap, and after a failure it retries after 1, 2, 4, 8,
16 and 32 minutes, then hourly, and resets on success. Just before writing, the
manifest is checked for writes by another device and merged if there were; every
write is then downloaded again and its hash compared; on a mismatch the backup
merges again, keeping everything earlier attempts saw (up to three times, then
"Backup conflict, will retry"), and
duplicate manifests are merged and the extras removed after verification.
Restore merges both ways, uploads local-only items, then downloads missing
recordings, applying everything in one transaction that keeps edits saved
meanwhile; a download moves into place only if its name is still free, under the
same lock that recording, import, rename and restore-from-Trash take. Per project id the newest `updatedAt` wins and per deletion identity
the newest `deletedAt` wins; a tombstone removes a song only when newer than its
`updatedAt`, and a recording only when newer than its `uploadedAt`, otherwise the
tombstone is dropped; a recording removed by a song tombstone keeps a tombstone
of its own, and deleting a song writes tombstones for every recording this device
knows for it, so reviving the song does not bring the deleted audio back. The one
exception is a recording that was never backed up and never on the deleting
device (say, recorded on an offline phone); if the song is revived before that
phone backs up, the recording is treated as new. Every merge gathers all its
inputs (local, earlier attempts, fresh and conflicting manifests, an archive)
before resolving tombstones once. Recordings are immutable: Drive's copy wins per identity, a
download is written only where no file exists when it commits, and a download
whose SHA-256 does not match the manifest is discarded and counted. Recordings
over 16 MiB are skipped with a visible count.

The older passphrase-encrypted backup (`rhymeai-projects.json` under RAI3/RAI2/RAI1,
recordings under RAI1) is only read, and only into Drive: with a stored
passphrase each backup decrypts it, uploads its recordings raw and merges its
songs into the v4 manifest without touching this device; deleted old recordings
are kept raw. The old files and the passphrase are removed only when every old
song and every old recording, deleted ones included, is verified in the new
backup; anything that cannot move keeps them, keeps "Migrate older
encrypted backup…" available and is counted in Settings. Without a passphrase
the old files are left alone and that row asks for it once.

When permanent song deletion cannot remove every recording, Android keeps a
pending cleanup record and reports that deletion is incomplete. It retries on
the next app launch or Trash purge. Recordings for pending deletions are omitted
from Drive uploads; Android Auto Backup retains the pending record with any
remaining files so cleanup resumes after restore. Android does not erase
previously uploaded recording bytes from Drive when a song is deleted.
Native two-platform exchange of v4 has not been verified.

The backup regressions run in `:app:testDebugUnitTest`:

| Case | Regression test | Behavior pinned |
| --- | --- | --- |
| V-1 | `BackupManifestTest.canonicalFormAndHashMatchTheSharedFixture`, `fixtureDecodesAndReEncodesByteForByte`, `canonicalEscapesOnlyTheContractCharactersAndSortsKeysByCodePoint` | Canonical JSON and `manifestSha256` match the shared fixture byte for byte. |
| V-2 | `BackupManifestTest.hashMismatchIsRefused`, `newerVersionIsRefusedEvenWithAValidHash`; `BackupServiceTest.hashMismatchedManifestIsRefusedAndNeverOverwrittenOrMerged` | A damaged or newer manifest is neither merged nor overwritten. |
| V-3 | `BackupServiceTest.backupMergesIntoDriveWritesRawRecordingsAndLeavesThisDeviceAlone`, `pendingLocalDeletionIsNeverUploaded`, `aRawFileWithoutMatchingMetadataIsUploadedAgain`, `backUpLeavesAnInterruptedRestoreAloneAndRestoreFinishesIt` | Backup writes v4 and raw recordings with `appProperties`, uploads each once, skips pending deletions, and leaves local data alone. |
| V-4 | `BackupServiceTest.restoreMergesBothWaysAndDownloadsOnlyVerifiedMissingRecordings`, `restoreNeverReplacesALocalRecording`; `RecordingSyncTest.restoreCommitKeepsADestinationThatAppearedAfterPlanning`, `aFailedCommitKeepsEverythingAlreadyInPlace`, `recoveryRemovesOnlyTheStagingFolder` | Restore merges both ways; hash-mismatched downloads are dropped; local files are never replaced, even ones that appear mid-restore. |
| V-5 | `BackupServiceTest.migrationDecisionTable`, `storedPassphraseMigratesIntoDriveOnlyVerifiesThenDeletesTheOlderBackup`, `anUnmovableOlderRecordingKeepsTheOlderBackupAndThePassphrase`, `aDifferentRecordingUnderTheSameNameIsNotCountedAsMoved`, `aDeletedOlderRecordingIsPreservedRawBeforeTheOlderBackupIsRemoved`, `aDeletedOlderRecordingThatCannotMoveKeepsTheOlderBackup` | Migration merges into Drive only and removes the old backup only after every song and recording is verified. |
| V-6 | `BackupServiceTest.independentIosShapedVectorsMigrateFromEveryEnvelopeVersion` | iOS-shaped RAI1, RAI2 and RAI3 backups migrate with their tombstones. |
| V-7 | `BackupSchedulerTest` (all), `BackupScheduleTest.backoffDoublesFromOneMinuteAndCapsAtOneHour` | Debounce, coalescing, backoff, leave-app interval and consent retry. |
| V-8 | `BackupArchiveTest.exportThenImportYieldsTheSameManifest`, `importMergesIntoTheLibraryAndAddsOnlyMissingRecordings`, `archivesWithUnsafeOrForeignEntriesAreRejected` | Export → Import yields the same manifest and merges; unsafe archives are refused. |
| V-9 | `BackupServiceTest.writerThatLandsBetweenOurWriteAndReadBackIsMergedNotLost`, `contentSeenInAnEarlierAttemptSurvivesAStaleWriterInBetween`, `aConflictingReadBackIsKeptEvenWhenAnotherWriterReplacesItBeforeTheRetry`, `aRemoteTombstoneThatArrivesDuringUploadsIsMergedBeforeTheFinalWrite`, `aStaleSongTombstoneSeenOnRetryStillDeletesTheOldTakeButNotTheNewerSong`, `aWriterThatNeverStopsIsReportedAsAConflict`, `duplicateManifestsAreMergedAndTheOlderOnesRemovedAfterVerification` | Lost-update protection and duplicate-manifest reconciliation. |
| V-10 | `RealDriveClientTest` | Drive listing follows every page and keeps `appProperties`; revoke posts the token. |
| T-1 | `SyncMergerTest.tombstonesConvergeByTimestampPrecedence`; `BackupServiceTest.tombstonesApplyByTimestampPrecedence`, `recordingTombstonesApplyByUploadTime`, `revivingASongDoesNotBringBackItsDeletedRecordings`; `BackupArchiveTest.importRevivesANewerSongButKeepsItsDeletedAudioDeleted`; `ProjectRepositoryTest.songDeletionTombstonesItsKnownRecordingsInTheSameWrite` | Tombstones remove only older songs and recordings; newer ones survive and drop the tombstone. |
| T-3 | `ProjectRepositoryTest.permanentDeleteWritesTombstoneBeforeSyncAndSurvivesRepositoryReopen` | A project tombstone is persisted, survives reopen and removes older copies. |
| T-4 | `ProjectRepositoryTest.expiryPurgeWritesTombstonesForBothSongsBeforeRemoteMerge` | Expiry purge persists a tombstone for each purged song. |
| T-5 | `ProjectRepositoryTest.deletionCommittedAfterBaseReadSurvivesSyncApplyAndLaterUpload` | A Delete Forever during the network window is not lost. |
| T-6 | `ProjectRepositoryTest.olderRemoteTombstoneKeepsASongEditedAfterTheSnapshot`, `applyKeepsAnEditSavedBetweenSnapshotAndCommit` | Applying a backup keeps local edits newer than it. |
| C-1 | `SyncBlobCryptoTest.independentPythonVectorsOpenForEveryEnvelopeVersionAndSealByteIdenticallyForWrittenOnes` | The legacy RAI1/RAI2/RAI3 vectors still open; the test-only writer reproduces them. |
| C-2 | `SyncBlobCryptoTest.manifestHeaderBodyAndTagTamperingFailsClosed`, `unknownAndTruncatedManifestHeadersAreDistinctFromAuthenticationFailure` | Tampered or unknown legacy envelopes fail closed during migration. |

The instrumented `BackupFlowInstrumentedTest` and `BackupSectionUiTest` cover the
Settings rows, the first-run sheet, Disconnect, and the tombstone, recording and
recording-only-import backup triggers through the real view model with a fake
Drive; `CertPinningInstrumentedTest.drivePinSetRejectsAnUnpinnedChain` checks the
Drive pins fail closed with a pin-verification failure. The earlier v2/v3
write-path suites (`DriveSyncServiceTest`, `ReceivingDeviceUploadTest`,
`DriveSyncUiStateTest`) were removed with the encrypted write path. Ported with
A3 timestamps: pending deletions never uploaded, a remote tombstone arriving
during uploads is merged before the final write and stops a second upload
(`aRemoteTombstoneThatArrivesDuringUploadsIsMergedBeforeTheFinalWrite`),
consent retry and the background interval (`BackupSchedulerTest`), oversize
recordings (`LargeRecordingSyncTest`). Their encryption-write cases were dropped
with that write path, and their tombstone-always-wins expectations were replaced
by the timestamp rule.

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
