# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo Shape

RhymeAI (app name "Writers Block") is a native-first songwriting assistant. The active pieces are:

- `android/` — Kotlin + Jetpack Compose app, package `com.rhymeai.app`. Gradle modules: `:app`, `:benchmark`, and `:kotlinllamacpp` (vendored llama.cpp binding in `android/third_party/kotlinllamacpp`).
- `Writers Block/` — SwiftUI + SwiftData iOS app. One shared scheme, `Writers Block`; unit tests in `Writers BlockTests` (Swift Testing), UI tests in `Writers BlockUITests` (XCTest).
- `shared/` — data both apps consume: `pronunciation/` (CMU dictionary TSV, word frequency, prosody fixtures) and `fixtures/` (golden JSON that pins cross-platform output).
- `finetune/` — Python (stdlib only) eval and training pipeline for the on-device Gemma models. `eval/prompts.py` and `eval/scoring.py` port the app's prompt builders and phonetics.
- `scripts/` — the local verification gate, release/live smoke gates, and asset generators.

The old React/Vite web variant has been removed. Do not reintroduce root `package.json`, `src/`, Vite, or Capacitor files unless Tyler explicitly asks for a web target again.

## Commands

Local gate from the repo root: Android `assembleDebug` + `testDebugUnitTest` + `lintDebug`, then iOS build + `Writers BlockTests`.

```sh
IOS_SIMULATOR_ID=<booted-iphone-udid> ./scripts/verify.sh
SKIP_IOS=1 ./scripts/verify.sh   # Android only; SKIP_ANDROID=1 for iOS only
```

Android, from `android/` with the wrapper. `verify.sh` points `JAVA_HOME` at Android Studio's bundled JBR when it is unset; do the same when calling Gradle directly.

```sh
./gradlew :app:compileDebugKotlin        # fastest compile check
./gradlew :app:testDebugUnitTest         # JVM unit tests
./gradlew :app:testDebugUnitTest --tests 'com.rhymeai.app.util.RhymeConstraintTest'   # one class; append .methodName for one test
./gradlew :app:lintDebug
./gradlew :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest # needs a running device or emulator
```

iOS, from the repo root. Confirm the destination with `xcrun simctl list devices` first.

```sh
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" \
  -destination "platform=iOS Simulator,id=<udid>" -parallel-testing-enabled NO \
  -only-testing:"Writers BlockTests"     # or "Writers BlockTests/RhymeConstraintTests" for one suite
```

`finetune` eval harness, from the repo root:

```sh
python3 -B -m unittest discover -s finetune/eval -p 'test_*.py'
python3 finetune/eval/run_eval.py --help   # real runs need llama-server and a GGUF; see finetune/README.md
```

Regenerate the pronunciation dictionary with `node scripts/generate-pronunciation-assets.mjs`. It writes `shared/pronunciation/cmudict-rhymeai.tsv`, which Android packages directly as an asset directory, and the iOS copy in `Writers Block/Writers Block/Resources/`.

Device-bound scripts (`verify.sh`, the `*-release-*` gates, `provider-live-smoke.sh`, the local-model smokes and the Gemma benchmark) need an explicitly selected, already-booted, disposable target in `IOS_SIMULATOR_ID`, `IOS_IPAD_SIMULATOR_ID` or `ANDROID_SERIAL` with Writers Block not installed. They refuse anything else and never boot, wipe, or uninstall a device. `README.md` documents each gate and its environment variables.

## Architecture

Each platform has one central state owner and wires its services by hand (no DI container):

- Android: `MainViewModel.kt` holds Compose `mutableStateOf` state. `data/repository/ProjectRepository.kt` persists to Preferences DataStore, and API keys go through `SecureKeyStore` (EncryptedSharedPreferences).
- iOS: `Writers_BlockApp.swift` builds the SwiftData `ModelContainer` (private CloudKit database, with a local-only fallback) and `EditorViewModel`, which reaches views through `@EnvironmentObject`. Settings live in `UserDefaults`; API keys live in Keychain (`Services/KeychainStore.swift`).

Most rhyme, prosody, prompt and export logic has a same-named file on each platform (`AIService`, `RhymeConstraint`, `ProsodyAnalyzer`, `NextLinePlacement`, `SectionMap`, `LyricsExporter`, `EditHistory`, …). The next-line suggestion path runs the same way on both:

1. `NextLinePlacement` and rhyme-context parsing find the cursor's stanza, its section, and the active rhyme-scheme letter.
2. `RhymeConstraint` builds the allowed end-word list from the shared CMU dictionary and word-frequency list. `ProsodyAnalyzer.tailRelation` classifies Perfect, Near and Slant, and the list is reordered by the complexity level.
3. `AIService` builds either a cloud prompt (Gemini, OpenAI or Claude; streamed; asks for 12 candidates) or an on-device prompt (a Rules list, six lines, lyrics trimmed by `localLyricWindow`).
4. Returned lines pass `RhymeLineFilter`, which keeps only the requested rhyme relation and never pads with misses.

On-device models: Android runs GGUFs through `service/LocalModelService.kt` and `:kotlinllamacpp`. iOS `Services/GGUFModelService.swift` compiles without llama.cpp and falls back to Apple Foundation Models; the real engine compiles in when the local package `Writers Block/LlamaFramework` (a prebuilt `llama.xcframework`) is linked. The shipped Gemma 4 E2B/E4B GGUFs are downloaded at runtime, and model weights stay out of the repo.

Sync: Android syncs through Google Drive (`data/sync/DriveSyncService.kt`); iOS syncs through CloudKit and also has `Services/GoogleDriveBackupService.swift`. Both write the encrypted SyncBlob v3 under the RAI3 envelope, still read v1/v2, and use tombstones so permanent deletes win merges. `scripts/generate-sync-envelope-vectors.py` produces the shared crypto test vectors.

## Parity Contracts

- `PARITY.md` records what must match between Android and iOS and the known differences. Update it when you change prompts, rhyme context, prosody, trash or sync, provider/model lists, or exports.
- `finetune/eval/prompts.py` mirrors the Android prompt builders in `service/AIService.kt` byte for byte, including the enum strings in `RewriteAction`, `SongSection` and `RhymeScheme`. Change it in the same commit as any prompt change, or eval baselines measure the wrong prompt.
- `shared/fixtures/local-lyric-window-v1.json` (generated by `finetune/eval/prompts.py`) and `shared/fixtures/complexity-end-words-v1.json` (generated by `finetune/eval/complexity_end_words_fixture.py`) pin byte-identical output. iOS tests read a copy at `Writers Block/Writers BlockTests/local-lyric-window-v1.json`, and an Android test fails if the copy drifts from the shared file.

## Working Rules

- Check `DESIGN.md` before UI changes. `AGENTS.md` has the longer contributor conventions and UI anti-patterns.
- Keep API keys out of source. Debug builds may embed a Gemini test key (`geminiTestKey` in gitignored `android/local.properties` becomes `BuildConfig.GEMINI_TEST_KEY`; iOS reads the `GEMINI_TEST_KEY` environment variable). Release builds leave it out, and the release smoke scripts scan the built artifacts for it. iOS Google Drive OAuth IDs go in the gitignored `Writers Block/Secrets.xcconfig` (template: `Secrets.example.xcconfig`).
- Do not commit screenshots, simulator captures, APKs, or files under `artifacts/`. The gate scripts write their evidence there.
