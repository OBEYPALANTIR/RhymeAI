# Parity Matrix

This tracks behavior that must stay aligned between Android and iOS.

## Provider and key handling

- Android: API keys are read on demand through `MainViewModel.apiKey(provider)`. Debug builds may fall back to `BuildConfig.GEMINI_TEST_KEY` for Gemini only when the secure store is blank.
- iOS: API keys are read on demand through `EditorViewModel.apiKey(for:)`. Debug builds may fall back to `GEMINI_TEST_KEY` for Gemini only when the Keychain is blank; UI tests can seed the existing in-memory keychain seam from the same environment variable.
- Parity status: Aligned for debug-only Gemini test-key fallback. Release builds keep the fallback empty or compiled out.
- Provider/model list parity: Android and iOS both list the same Gemini, OpenAI, Claude, and local model IDs in provider-picker order. OpenAI/Claude happy paths remain BYO-key manual smoke items.

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
- iOS trash lifecycle: In-memory SwiftData unit-verified that moving the current project to trash clears editor state, creates a 30-day trash entry, collapses duplicate trash rows with the same ID, restore collapses duplicate active/trash rows with the same ID, and purge removes only expired trash.
- Import/autosave persistence: Android instrumented-verified that imported projects and debounced autosaves persist projects, current project ID, and editor state through DataStore and restore through a fresh ViewModel. iOS in-memory SwiftData unit-verified that imported projects and debounced autosaves persist the expected project fields and select the imported/saved project for editing.

## Prosody checks

- Android and iOS unit-verified shared dictionary stress counting, IPA stress markers, fallback syllable counts, punctuation/digit normalization, internal apostrophe retention, CMU rhyme keys, multi-pronunciation rhyme keys, stopword filtering, and short unknown-word rhyme suppression.

## Local model checks

- Android Gemma GGUF download helpers are unit-verified for missing, incomplete, non-GGUF, valid GGUF, resumable partial download, HTTP failure, no-storage messaging, and progress formatting.
- Android local provider/model handling is unit-verified: the Local picker exposes only `local-model`, and suggestions, streaming, rewrites, and synonyms surface the shared no-model-loaded message without requiring an API key.
- iOS local provider/model switching is unit-verified: the Local picker exposes only `local-model`, selecting Local moves the current model to the on-device model, and Local does not require an API key.

## Rhyme context checks

- Android and iOS unit-verified that section headers do not consume rhyme-scheme positions, latest previous lyric lines with the same scheme letter become the rhyme target, current section detection reaches prompt shaping, and empty lyrics use the first active scheme letter. Android pure seam additionally verifies cursor clamping and empty-scheme fallback to `A`.

## Open parity checks

- Local model live/inference path: Android GGUF model load and inference still need an emulator smoke with an actual model file; iOS local provider depends on Apple Foundation Models availability and still needs a simulator/device availability smoke.
- OpenAI/Claude happy paths: Pending manual smoke only if Tyler supplies keys; no-key/status/error messages are unit-verified.
