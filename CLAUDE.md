# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo Shape

RhymeAI (app name "Writers Block") is a native-first songwriting assistant. The active pieces are:

- `android/` — Kotlin + Jetpack Compose app, package `com.rhymeai.app`. Gradle modules: `:app`, `:benchmark`, and `:kotlinllamacpp` (vendored llama.cpp binding in `android/third_party/kotlinllamacpp`, which needs NDK 27.0.12077973 and CMake 3.22.1).
- `Writers Block/` — SwiftUI + SwiftData iOS app. One shared scheme, `Writers Block`; unit tests in `Writers BlockTests` (Swift Testing), UI tests in `Writers BlockUITests` (XCTest).
- `shared/` — data both apps consume: `pronunciation/` (CMU dictionary TSV, word frequency, prosody fixtures) and `fixtures/` (golden JSON that pins cross-platform output).
- `finetune/` — the on-device Gemma pipeline. `eval/` is stdlib-only Python that replays the app's on-device prompts against a GGUF and scores the output; `train/` needs unsloth, torch and trl.
- `scripts/` — the local verification gate, release/live smoke gates, and asset generators.

Main UI surfaces: Android `ui/screens/EditorScreen.kt` and `ui/components/AssistantPanel.kt`; iOS `Views/EditorView.swift`, `AssistantPanelView.swift`, `ProjectsDrawerView.swift` and `TrashBinView.swift`.

The old React/Vite web variant has been removed. Do not reintroduce root `package.json`, `src/`, Vite, or Capacitor files unless Tyler explicitly asks for a web target again.

## Commands

Local gate from the repo root: Android `assembleDebug` + `testDebugUnitTest` + `lintDebug`, then iOS build + `Writers BlockTests`.

```sh
IOS_SIMULATOR_ID=<booted-iphone-udid> ./scripts/verify.sh
SKIP_IOS=1 ./scripts/verify.sh   # Android only, needs no device; SKIP_ANDROID=1 for iOS only
```

Android, from `android/` with the wrapper. `verify.sh` points `JAVA_HOME` at Android Studio's bundled JBR when it is unset; do the same when calling Gradle directly.

```sh
./gradlew :app:compileDebugKotlin        # fastest compile check
./gradlew :app:testDebugUnitTest         # JVM unit tests
./gradlew :app:testDebugUnitTest --tests 'com.rhymeai.app.util.RhymeConstraintTest'   # one class; append .methodName for one test
./gradlew :app:lintDebug
./gradlew :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest # installs onto the connected device or emulator
```

iOS, from the repo root. Confirm the destination with `xcrun simctl list devices` first. The first build resolves the local package `Writers Block/LlamaFramework`, which downloads the pinned llama.cpp xcframework from GitHub, so it needs network access.

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

Asset generators: `node scripts/generate-pronunciation-assets.mjs` downloads the CMU dictionary and writes `shared/pronunciation/cmudict-rhymeai.tsv` (Android packages that directory as assets) plus the iOS copy in `Writers Block/Writers Block/Resources/`. `scripts/generate-word-frequency.py` rebuilds `word-frequency.txt` and needs `wordfreq` in a venv.

Device-bound scripts (`verify.sh`, the `*-release-*` gates, `provider-live-smoke.sh`, the local-model smokes and the Gemma benchmark) need an explicitly selected, already-booted, disposable target in `IOS_SIMULATOR_ID`, `IOS_IPAD_SIMULATOR_ID` or `ANDROID_SERIAL` (an `emulator-NNNN`; physical phones are refused) with Writers Block (`ShaydeTree.Writers-Block`) not installed. They never boot, wipe, or uninstall a device. The raw `connectedDebugAndroidTest` and `xcodebuild test` commands have no such guard, so point them at a disposable target too. `README.md` documents each gate and its environment variables.

GitHub Actions run Android `testDebugUnitTest` and `assembleDebug` and iOS `Writers BlockTests`, filtered by path. Nothing in CI runs lint or the `finetune` tests.

## Architecture

Each platform has one central state owner and wires its services by hand (no DI container):

- Android: `MainViewModel.kt` holds Compose `mutableStateOf` state. `data/repository/ProjectRepository.kt` persists to Preferences DataStore, and API keys go through `SecureKeyStore` (EncryptedSharedPreferences).
- iOS: `Writers_BlockApp.swift` builds the SwiftData `ModelContainer` (private CloudKit database, with a local-only fallback) and `EditorViewModel`, which reaches views through `@EnvironmentObject`. Settings live in `UserDefaults`; API keys live in Keychain (`Services/KeychainStore.swift`).

Most rhyme, prosody, prompt and export logic has a same-named file on each platform (`AIService`, `RhymeConstraint`, `ProsodyAnalyzer`, `NextLinePlacement`, `SectionMap`, `LyricsExporter`, `EditHistory`, …). The next-line suggestion path runs the same way on both:

1. `NextLinePlacement` and rhyme-context parsing find the cursor's stanza, its section, and the active rhyme-scheme letter.
2. `RhymeConstraint` builds the allowed end-word list for the requested relation (Perfect, Near or Slant) from the shared CMU dictionary and word-frequency list, then applies the complexity level: Complex puts multi-syllable words first, and Simple keeps only one-syllable words when at least six exist.
3. `AIService` builds either a cloud prompt (Gemini, OpenAI or Claude; streamed; asks for 12 lines instead of 6 when a rhyme constraint applies) or an on-device prompt (a Rules list asking for six lines, lyrics trimmed by `localLyricWindow`).
4. Returned lines pass `RhymeLineFilter`, which keeps only the requested relation, ranks by syllable distance, cuts back to the suggestion count, and never pads with misses.

On-device models: Android runs GGUFs through `service/LocalModelService.kt` and `:kotlinllamacpp`. iOS `Services/GGUFModelService.swift` uses llama.cpp when the `llama` product from `Writers Block/LlamaFramework` is linked (it is in the checked-in project) and otherwise falls back to Apple Foundation Models. `Writers Block/Frameworks/` is an archived build that is not linked. The shipped Gemma 4 E2B/E4B GGUFs are downloaded at runtime, and model weights stay out of the repo.

Sync: iOS syncs songs through CloudKit, managed by SwiftData. Android `data/sync/DriveSyncService.kt` and iOS `Services/GoogleDriveBackupService.swift` exchange an encrypted SyncBlob: they write v3 under the RAI3 envelope, still read v1 and v2, and use tombstones so permanent deletes win merges. Recording files stay in the RAI1 format. `scripts/generate-sync-envelope-vectors.py` (needs the `cryptography` package) writes the Android test vectors, and iOS tests embed their own copy.

## Parity Contracts

- `PARITY.md` records what must match between Android and iOS and the known differences. Update it when you change prompts, rhyme context, prosody, trash or sync, provider/model lists, or exports.
- `finetune/eval/prompts.py` mirrors the Android on-device prompt builders in `service/AIService.kt` byte for byte, along with the enum strings in `RewriteAction`, `SongSection` and `RhymeScheme` and the iOS Gemma turn envelope in `GGUFModelService.swift`. Change it in the same commit as any on-device prompt change, or eval baselines measure the wrong prompt. Cloud prompts are not ported.
- `shared/fixtures/local-lyric-window-v1.json` pins the on-device lyric window across Android, iOS and the eval. iOS tests read a copy at `Writers Block/Writers BlockTests/local-lyric-window-v1.json`, and an Android test fails if the copy drifts from the shared file.
- `shared/fixtures/complexity-end-words-v1.json` pins Android and the eval word for word. Regenerate it with `cd finetune && python3 -m eval.complexity_end_words_fixture`. iOS checks the same rule against its own bundled dictionary instead.

## Working Rules

- Check `DESIGN.md` before UI changes. `AGENTS.md` has the longer contributor conventions and UI anti-patterns.
- Keep API keys out of source. A debug Android build embeds `geminiTestKey` from gitignored `android/local.properties` as `BuildConfig.GEMINI_TEST_KEY` only with `-PincludeGeminiTestKey=true`. iOS debug builds read the `GEMINI_TEST_KEY` environment variable when the Keychain is blank. Release builds leave the key out, and the release smoke scripts scan the built artifacts for it. iOS Google Drive OAuth IDs go in the gitignored `Writers Block/Secrets.xcconfig` (template: `Secrets.example.xcconfig`).
- Do not commit screenshots, simulator captures, APKs, or files under `artifacts/`. That directory is gitignored, and the visual-audit, walkthrough and benchmark scripts write their evidence there.
