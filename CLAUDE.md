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
4. Returned lines pass `RhymeLineFilter`, which keeps only the requested relation in arrival order, cuts back to the suggestion count, and never pads with misses.

On-device models: Android runs GGUFs through `service/LocalModelService.kt` and `:kotlinllamacpp`. iOS `Services/GGUFModelService.swift` uses llama.cpp when the `llama` product from `Writers Block/LlamaFramework` is linked (it is in the checked-in project) and otherwise falls back to Apple Foundation Models. `Writers Block/Frameworks/` is an archived build that is not linked. The shipped Gemma 4 E2B/E4B GGUFs are downloaded at runtime, and model weights stay out of the repo.

Sync: iOS syncs songs through CloudKit, managed by SwiftData. Android `data/sync/DriveSyncService.kt` and iOS `Services/GoogleDriveBackupService.swift` back up to Drive `appDataFolder` as manifest v4: plain `rhymeai-manifest.json` with a canonical-JSON `manifestSha256` (`BackupManifest.kt` on Android) plus raw `rec_<recordingId>` recordings; each recording has a stable UUID and a per-device record (precedence time, hash, location) in DataStore. Backup merges this device into Drive; Restore merges both ways; a tombstone wins over an older real time and over any repaired (first-seen) time, and a song that loses only to that rule is kept aside on the device. The older passphrase-encrypted RAI1/RAI2/RAI3 backup is only read, to migrate it into Drive (`SyncBlobCrypto`). The iOS side of v4 is pending its companion PR. `scripts/generate-sync-manifest-v4-fixture.py` (stdlib) writes `shared/fixtures/sync-manifest-v4.json`; `scripts/generate-sync-envelope-vectors.py` (needs `cryptography`) writes the legacy decrypt vectors.

## Parity Contracts

- `PARITY.md` records what must match between Android and iOS and the known differences. Update it when you change prompts, rhyme context, prosody, trash or sync, provider/model lists, or exports.
- `finetune/eval/prompts.py` mirrors the Android on-device prompt builders in `service/AIService.kt` byte for byte, along with the enum strings in `RewriteAction`, `SongSection` and `RhymeScheme` and the iOS Gemma turn envelope in `GGUFModelService.swift`. Change it in the same commit as any on-device prompt change, or eval baselines measure the wrong prompt. Cloud prompts are not ported.
- `shared/fixtures/local-lyric-window-v1.json` pins the on-device lyric window across Android, iOS and the eval. iOS tests read a copy at `Writers Block/Writers BlockTests/local-lyric-window-v1.json`, and an Android test fails if the copy drifts from the shared file.
- `shared/fixtures/sync-manifest-v4.json` pins the backup manifest's canonical JSON and hash. Regenerate it with `python3 scripts/generate-sync-manifest-v4-fixture.py` (`--check` to verify). iOS tests read a copy at `Writers Block/Writers BlockTests/sync-manifest-v4.json`; Android `BackupManifestTest` fails if the copy drifts and skips while it is absent.
- `shared/fixtures/archive-names-v1.json` pins the export-archive name of every recording (A39). Regenerate it with `python3 scripts/generate-archive-names-fixture.py` (`--check` to verify). iOS keeps a byte-identical copy at `Writers Block/Writers BlockTests/archive-names-v1.json`; Android `BackupArchiveTest` fails if the copy drifts and skips while it is absent.
- `shared/fixtures/complexity-end-words-v1.json` pins Android and the eval word for word. Regenerate it with `cd finetune && python3 -m eval.complexity_end_words_fixture`. iOS checks the same rule against its own bundled dictionary instead.

## Working Rules

- Check `DESIGN.md` before UI changes. `AGENTS.md` has the longer contributor conventions and UI anti-patterns.
- Keep API keys out of source. A debug Android build embeds `geminiTestKey` from gitignored `android/local.properties` as `BuildConfig.GEMINI_TEST_KEY` only with `-PincludeGeminiTestKey=true`. iOS debug builds read the `GEMINI_TEST_KEY` environment variable when the Keychain is blank. Release builds leave the key out, and the release smoke scripts scan the built artifacts for it. iOS Google Drive OAuth IDs go in the gitignored `Writers Block/Secrets.xcconfig` (template: `Secrets.example.xcconfig`).
- Do not commit screenshots, simulator captures, APKs, or files under `artifacts/`. That directory is gitignored, and the visual-audit, walkthrough and benchmark scripts write their evidence there.

## Harness: RhymeAI

**Goal:** land cross-platform RhymeAI changes (Android, iOS, eval) on `main` with run evidence and an independent review, and improve the on-device models through the teacher-data and Colab student pipelines.

**Issue tracking:** GitHub Issues — the orchestrator pulls ready work with `gh issue list --state open` / `gh issue view <n>`; status is written back by a `gh issue comment` with the merge commit, and the PR's `Fixes #<n>` closes the issue when it merges into the default branch (otherwise `gh issue close`).

**Entry point — applies to every prompt in this repo:** You MUST invoke the `rhymeai-orchestrator` skill *before* responding to any request — new work, a follow-up, a re-run, a question, or a change to a previous result. It is the single entry point; do not craft a response outside it. The orchestrator decides what happens next: it answers trivial or out-of-RhymeAI requests directly and runs the agents only when the work warrants it.

**Delegated agents are exempt from the gate:** when you are running as one of the harness's workers (`rhymeai-implementer`, `rhymeai-verifier`, `rhymeai-model-trainer`, `android-m3-expressive-designer`, or any agent the orchestrator spawned with a delegation prompt), do not invoke `rhymeai-orchestrator`; do the delegated task and return your report. The gate applies to the session's top-level conversation only.

**Change history:**
| Date | Change | Target | Reason |
|------|--------|--------|--------|
| 2026-10-08 | Initial setup: orchestrator, 3 agents, 4 skills, tools registry; 74 off-domain skills archived locally | All | harness review found no entry point and no skill for the real workflows |
| 2026-10-08 | Tool discovery: registered kotlin-lsp, swift-lsp, gguf-py, colab-mcp, inspect-ai by role; secret gists kept as evidence host | `skills/rhymeai-orchestrator/references/tools.md` | owner accepted each candidate; language servers and Colab MCP installed at user scope |
| 2026-10-08 | Delegated agents exempted from the entry-point gate; model work routed to the trainer before implementation; designer agent memory path made checkout-relative | `CLAUDE.md`, `skills/rhymeai-orchestrator`, `agents/*` | Codex review of PR 92: recursive orchestration, wrong phase order, checkout-specific path |
| 2026-10-08 | iOS test command in the registry now carries project, scheme and destination; `.agents/worktrees/` ignored in the shared gitignore | `references/tools.md`, `.gitignore` | Codex review of PR 92, second pass |
| 2026-10-08 | Workers declare their skills in frontmatter so they load at spawn; designer memory exclusions narrowed to generic code | `agents/*` | Codex review of PR 92, third pass |
| 2026-10-08 | iOS tests registered as the guarded `scripts/verify.sh` stage; issue closure made conditional on an issue existing | `references/tools.md`, `skills/rhymeai-orchestrator` | Codex review of PR 92, fourth pass |
| 2026-10-08 | iOS fallback no longer skips the simulator guards; evidence host has no hook-bypassing fallback; designer memory moved to user scope so it survives worktree removal | `references/tools.md`, `agents/android-m3-expressive-designer.md` | Codex review of PR 92, fifth pass |
| 2026-10-08 | Delivery records the merge SHA with `gh issue comment` (the PR's `Fixes #<n>` already closes the issue); Compose/UI changes run the AGENTS.md UI-polish command list | `skills/rhymeai-orchestrator`, `references/tools.md`, `agents/rhymeai-verifier.md`, `CLAUDE.md` | Codex review of PR 92, sixth pass |
| 2026-10-08 | UI-polish-pass tasks stay on `chore/ui-polish-2026-05`; visual changes attach before/after screenshots to the PR | `skills/rhymeai-pr-evidence` | Codex review of PR 92, seventh pass |
| 2026-10-08 | UI-polish-pass tasks branch from and target `chore/ui-polish-2026-05` in the orchestrator gate too, with the pass's full commit-scope list | `skills/rhymeai-orchestrator`, `skills/rhymeai-pr-evidence` | Codex review of PR 92, eighth pass |
| 2026-10-08 | Designer consultation in the scope phase is read-only and edits only in a given worktree; merge cleanup removes the worktree before deleting the branch explicitly | `agents/android-m3-expressive-designer.md`, `skills/rhymeai-orchestrator`, `skills/rhymeai-pr-evidence` | Codex review of PR 92, ninth pass |
| 2026-10-08 | The orchestrator creates the task worktree and branch before delegating implementation, once per task; correction rounds reuse it | `skills/rhymeai-orchestrator` | Codex review of PR 92, tenth and twelfth passes |
| 2026-10-08 | Mutating UI tasks (`spotlessApply`, Roborazzi recording) run and are committed by the implementer; the verifier runs only checks and confirms a clean worktree | `references/tools.md`, `agents/rhymeai-implementer.md`, `agents/rhymeai-verifier.md` | Codex review of PR 92, eleventh pass |
| 2026-10-08 | The guarded iOS stage is run by the verifier only, which uninstalls the app the stage installed right after, so later rounds pass the app-not-installed guard | `references/tools.md`, `skills/rhymeai-pr-evidence`, `agents/rhymeai-verifier.md`, `agents/rhymeai-implementer.md` | Codex review of PR 92, thirteenth pass |
| 2026-10-08 | iOS teardown runs only when the stage passed its preflight; a follow-up whose worktree is missing recreates it from the PR head | `references/tools.md`, `agents/rhymeai-verifier.md`, `skills/rhymeai-orchestrator` | Codex review of PR 92, fourteenth pass |
| 2026-10-08 | Scoping and the designer consult read the freshly fetched base ref, not the possibly stale primary checkout; the designer's memory note matches its user scope | `skills/rhymeai-orchestrator`, `agents/android-m3-expressive-designer.md` | Codex review of PR 92, fifteenth pass |
| 2026-10-08 | Merges pin the reviewed head (`--match-head-commit`); instrumented tests run the isolated QA app on the selected emulator only; an `ios-device` row keeps the authorized simulator free of leftover installs; the UI-polish branch is used only when the owner assigns a task to that pass; agents spawn by their own type; follow-up worktrees fast-forward to the PR head; new branches don't track `origin/main`; issue closure no longer assumes a default-branch merge; `pr-watch` and `native-ui` roles replace hard tool names in the skills | `references/tools.md`, `skills/*`, `agents/*`, `.gitignore`, `CLAUDE.md` | Codex review of PR 92, sixteenth pass, and a full read of the harness against the repo |
| 2026-10-08 | The `pr-watch` fallback reads inline review comments through `gh api` and treats `no checks reported` as no CI rather than a failure | `references/tools.md` | Codex review of PR 92, seventeenth pass |
| 2026-10-08 | Fixes pushed after verification go back through the implementer and verifier before re-review, and merge waits for the verifier's round on the final head; workflow-file changes count as check-producing paths | `skills/rhymeai-orchestrator`, `skills/rhymeai-pr-evidence`, `references/tools.md` | Codex review of PR 92, eighteenth pass |
| 2026-10-20 | Harness re-landed on current `main` (PR 92 reconciled after PRs 99 and 114 rewrote `CLAUDE.md`): `.gitignore` un-ignores the harness; registry rows for `kotlin-lsp`, `swift-lsp`, `colab-mcp` and `inspect-ai` marked optional; `ci` row names `android-apk.yml`/`jules-ci.yml` triggers; `android-unit-tests` JBR path matches `verify.sh`; `eval_student.py` placed in the colab package; parity skill's divergence example and table row follow `PARITY.md` on `main`; teacher-data and student-model paths no longer pin one version | `CLAUDE.md`, `.gitignore`, `references/tools.md`, `skills/rhymeai-parity`, `skills/rhymeai-teacher-data` | main moved past the PR's merge base; stale references found in a reference audit |
