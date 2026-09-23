# Parity Matrix

This tracks behavior that must stay aligned between Android and iOS. Source contracts are distinct from verification evidence; current acceptance must name its exact source and artifact.

## Model setup return path and contrast (2026-09-22)

- Android preserves the mounted UnBlock panel beneath Settings. Close and system Back return to the same panel, including expanded controls; Settings opened from the song returns to the song. The theme supplies a semantic default foreground so model status remains readable in Graphite.
- iOS already presents model setup as a child sheet. A new UI regression verifies Done returns to Assistant in Graphite, Paper, and Ink, then closing Assistant returns to the editor.
- Android: two regression tests passed on the phone, 1.3 font scale with animations disabled, and an expanded-size emulator profile. Tests exercise ready/setup display states, rendered light model-status pixels, both return paths, and preserved expansion. These display-state tests do not prove model inference. Build, 338 unit tests (five skipped), and lint (zero errors, 84 warnings) passed.
- iOS: the appearance round-trip test passed on the existing iPhone simulator at default and accessibility-large text with increased contrast. Testing used a command-line iOS 18 deployment-target override because the test target otherwise defaults to iOS 27; project settings were unchanged.
- Local evidence: `~/.agents/artifacts/2026-09-22/model-navigation/`. Targeted emulator/simulator evidence only; full accessibility, iPad, physical-device, provider, and store-release qualification remain outside this check.

## Song recordings

- Open the recording library from the active song's editor. The song selector contains songs only; recording trash remains in Trash Bin.
- Import M4A, MP3, WAV, or AAC audio into the song selected when the library opens. Imports preserve the original audio bytes, use app-owned storage, and require no microphone permission.
- Reject empty, unsupported, invalid audio, or files larger than 100 MiB. Cancellation and failed validation remove staged files; duplicate names keep both recordings.
- Imported formats retain their extension through rename, trash, restore, and backup. Existing M4A backup names remain unchanged.
- Apple backup manifests use schema 3 / authenticated RAI3 and require an updated Apple app; legacy RAI1/v1 and RAI2/v2 reads remain supported. Android still uses RAI1 and cannot read Apple RAI2/RAI3 backups; the existing cross-platform protocol gap is tracked separately in PR #36. Older Apple apps also cannot read Android backups containing the newly imported formats.
- Native Mac follows the same import contract in its existing song-level library; that unfinished app is maintained in a separate worktree from the mobile targets.
- Validation for this change is tracked separately from historical evidence below. Live cloud backup, store delivery, and native Mac UI acceptance are not established by source or build checks.

## Writing and motion contract

- Local is the initial provider and first setup option. Preserve valid saved provider/model choices; missing local weights open local setup rather than falling back to cloud.
- Suggestion text is passive. Use line explicitly inserts; Keep for later does not edit the song. Insertion offers Undo without reversing subsequent unrelated typing.
- Focus temporarily hides secondary controls and the assistant, then restores their prior visibility and preferences.
- Templates use native bottom-origin sheets. Selection indicators travel, disclosures expand, provider forms transition, and editor controls animate on entry/exit. Recording and UnBlock controls share spring timing. Typing and lyric selections stay immediate; rewrite targets remain stationary, with one progress indicator for loading.
- Motion exists to explain feedback, state, or spatial origin. Reduced Motion removes app-owned travel and scale. Real recording amplitude and native direct manipulation remain useful feedback.

## Historical verification boundary

The checks below retain earlier evidence, including July and September 2026 work. They do not certify this combined candidate or establish current live provider, sync, store, or release acceptance. The recording contract above supersedes older statements implying universal backup-envelope compatibility.

## Provider and key handling

- Android: API keys are read on demand through `MainViewModel.apiKey(provider)`. Debug builds may fall back to `BuildConfig.GEMINI_TEST_KEY` for Gemini only when the secure store is blank.
- iOS: API keys are read on demand through `EditorViewModel.apiKey(for:)`. Debug builds may fall back to `GEMINI_TEST_KEY` for Gemini only when the Keychain is blank; UI tests can seed the existing in-memory keychain seam from the same environment variable.
- Parity status: Aligned for debug-only Gemini test-key fallback. Release builds keep the fallback empty or compiled out.
- Provider/model list parity: Android and iOS both list the same Gemini, OpenAI, Claude, and local model IDs in provider-picker order. OpenAI/Claude happy paths are scriptable through `scripts/provider-live-smoke.sh` when BYO keys are supplied.

## Gemini live checks

- Gemini live suggestion and rewrite flow: Verified on Android with `GeminiSdkLiveGateTest`; verified on iOS with `Writers Block Gemini Live` user scheme and `Writers_BlockTests.geminiSuggestionRewriteAndStreamingPathsWorkWithDebugKey`.
- Gemini rewrite actions: `REPHRASE` / `rephrase`, `HARDER_RHYME` / `harderRhyme`, and `PUNCH_UP` / `punchUp` are live-verified on both platforms.
- Gemini streaming: Verified on Android and iOS through the same live tests.
- Gemini service-level stream cancellation: Live-verified on Android and iOS by cancelling the Gemini suggestion stream after the first emitted suggestion.
- Gemini Android UI cancel behavior: Instrumented UI-verified that the assistant button changes from `Suggest Next Line` to `Stop`, cancels the in-flight suggestion request, and returns to `Suggest Next Line`.
- Gemini iOS UI cancel behavior: Simulator UI-verified that the assistant button changes from `Suggest Next Line` to `Stop`, cancels the in-flight suggestion request, and returns to `Suggest Next Line`.
- Gemini invalid-key failure: Verified on Android and iOS; failures use user-facing messages and do not echo the invalid key.
- Gemini timeout/offline and blocked-response failures: Unit-verified on Android and iOS; Android emulator offline and iOS simulator unreachable-endpoint UI smokes verify timeout/offline failures use the shared connection retry message and return to `Suggest Next Line`; blocked/safety responses use the shared blocked-response message.
- Gemini suggestion response parsing: Aligned for line responses, JSON arrays, JSON object array wrappers, numbering/bullets, duplicate suggestions, prompt echo, provider markers, and overlong lines.
- Gemini prompt shaping: Unit-verified on both platforms for immediate vs whole-song context, target-rhyme vs new-rhyme instructions, section hints, complexity, six-line output contract, and every rewrite action instruction.
- Rewrite action UI walkthrough: Android instrumented and iOS simulator UI-verified that `Rephrase`, `Harder Rhyme`, and `Punch Up` each open the inline rewrite review controls and that `Cancel` returns to the rewrite chip bar.
- Gemini empty suggestion stream: Android and iOS both surface `AI did not return suggestions. Try again.` instead of leaving a blank result.
- Gemini no-key and provider status failures: Unit-verified on both platforms for suggestions, streaming, rewrite, synonyms, rejected-key, missing-model, rate-limit, and service-error user messages before provider bodies can leak into UI text.

## Export checks

- TXT export: Android and iOS unit-verified for untitled fallback, optional theme header, and lyric text preservation.
- LRC export: Android and iOS unit-verified for shared metadata headers, blank-line handling, leading lyric indentation preservation, and trailing horizontal whitespace trimming.
- JSON export: Android and iOS unit-verified for project field round trip. Platform timestamp encodings differ by model type (`Long` on Android, ISO-8601 `Date` on iOS), but each export remains re-importable on its source platform.
- PDF export: iOS unit-verified to produce PDF bytes from a long lyric sheet. Android instrumented-verified that a long lyric sheet produces readable PDF bytes, paginates through `PdfRenderer`, and renders visible ink on the first page.

## Trash and persistence checks

- Android sync merge: Unit-verified that active project changes merge by `updatedAt`, trash entries merge by `deletedAt`, newer trash removes stale active copies, and newer restored active projects are not deleted by stale trash entries.
- iOS trash lifecycle and CloudKit readiness: In-memory SwiftData unit-verified that moving the current project to trash clears editor state, creates a 30-day trash entry, collapses duplicate trash rows with the same ID, restore collapses duplicate active/trash rows with the same ID, and purge removes only expired trash. `scripts/ios-cloudkit-readiness.sh` verifies the private CloudKit container, entitlements, remote-notification background mode, build output, and trash conflict tests before live sync.
- Import/autosave persistence: Android instrumented-verified that imported projects and debounced autosaves persist projects, current project ID, and editor state through DataStore and restore through a fresh ViewModel. iOS in-memory SwiftData unit-verified that imported projects and debounced autosaves persist the expected project fields and select the imported/saved project for editing.

## Prosody checks

- Android and iOS unit-verified shared dictionary stress counting, IPA stress markers, fallback syllable counts, punctuation/digit normalization, internal apostrophe retention, CMU rhyme keys, multi-pronunciation rhyme keys, stopword filtering, and short unknown-word rhyme suppression.

## Local model checks

- Android Gemma GGUF download helpers are unit-verified for missing, incomplete, non-GGUF, valid GGUF, resumable partial download, HTTP failure, no-storage messaging, and progress formatting.
- Android local provider/model handling is unit-verified: the Local picker exposes only `local-model`, and suggestions, streaming, rewrites, and synonyms surface the shared no-model-loaded message without requiring an API key. A live `LocalModelInstrumentedTest` gate is wired through `scripts/android-local-model-smoke.sh` and passed on `emulator-5554` with an ignored TinyLlama Q2 GGUF fixture.
- iOS local provider/model switching is unit-verified: the Local picker exposes only `local-model`, selecting Local moves the current model to the on-device model, and Local does not require an API key.

## Rhyme context checks

- Android and iOS unit-verified that section headers do not consume rhyme-scheme positions, latest previous lyric lines with the same scheme letter become the rhyme target, current section detection reaches prompt shaping, and empty lyrics use the first active scheme letter. Android pure seam additionally verifies cursor clamping and empty-scheme fallback to `A`.

## Cloud backup parity checks

- Encrypted blob compatibility: statically audit-verified 2026-07-05 that both
  platforms use PBKDF2-HMAC-SHA256 at 210,000 iterations with a 256-bit key,
  AES-256-GCM with a 128-bit tag, and the byte-identical
  `RAI1 | salt(16) | iv(12) | ciphertext | tag(16)` envelope with the header
  bound as AAD. The shared RAI1 golden vector is now pinned by unit tests on
  both platforms (`BackupCoreTests` on iOS, `SyncBlobCryptoTest` on Android).
- Backup passphrase rules: both platforms trim the ASCII set space/tab/CR/LF
  and require at least 8 printable ASCII (0x20–0x7E) characters, unit-verified
  on both sides including tab/newline-padded and interior-tab cases.
- Drive HTTP error mapping: 401 re-auth, 403/429 retry-later, 5xx server-error,
  and generic fallback buckets are aligned; neither platform echoes raw
  response bodies into user-facing text.
- Trash retention: 30 days on both platforms
  (`TrashedSongProject.kt` / `TrashedSongProject.swift`).
- Prompt templates: section labels, rhyme-constraint blocks, rewrite action
  instructions, and the Gemma chat template are byte-identical across
  platforms (iOS softens punch-up wording only on the Apple Intelligence
  local path due to on-device guardrails).
- Syllable coloring: identical two-toggle semantics — syllables on with rhyme
  highlight off tints whole words semibold; with rhyme highlight on, syllable
  color moves to the underline.

## Open parity checks

- Local model live/inference path: Android has historical emulator evidence for GGUF load and nonblank generation through `scripts/android-local-model-smoke.sh`; iOS local provider has a simulator/device smoke gate that passes when Apple Foundation Models either return text or surface an on-device availability reason.
- CloudKit live sync matrix: Static readiness is scriptable, but create/edit/concurrent edit/offline/delete/trash propagation still needs the live iCloud-signed-in two-simulator/device matrix in `docs/CLOUDKIT_SYNC_CHECKLIST.md`.
- Release walkthrough: iOS has a Release-configuration UI gate for create/save/export surface/graceful no-key AI/rewrite/relaunch persistence through `scripts/ios-release-walkthrough.sh`, a visual walkthrough screenshot gate for welcome, populated editor, export, assistant, and no-key AI/rewrite error states through `scripts/ios-release-visual-walkthrough.sh`, and a light/dark iPhone/iPad screenshot gate through `scripts/ios-release-visual-audit.sh`; Android has passing minified release APK walkthroughs for create/save/export surface/graceful no-key suggestion/force-stop/relaunch persistence through `scripts/android-release-walkthrough.sh`, live Gemini suggestion/rewrite preview through `scripts/android-release-live-gemini.sh`, and phone/tablet light/dark/large-font populated-surface screenshot coverage through `scripts/android-release-visual-audit.sh`.
- OpenAI/Claude happy paths: `scripts/provider-live-smoke.sh` is wired for BYO-key suggestion, rewrite, and streaming checks on both platforms; the live run is pending supplied keys. No-key/status/error messages are unit-verified.
