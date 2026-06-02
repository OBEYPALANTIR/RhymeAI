# Parity Matrix

This tracks behavior that must stay aligned between Android and iOS.

## Provider and key handling

- Android: API keys are read on demand through `MainViewModel.apiKey(provider)`. Debug builds may fall back to `BuildConfig.GEMINI_TEST_KEY` for Gemini only when the secure store is blank.
- iOS: API keys are read on demand through `EditorViewModel.apiKey(for:)`. Debug builds may fall back to `GEMINI_TEST_KEY` for Gemini only when the Keychain is blank; UI tests can seed the existing in-memory keychain seam from the same environment variable.
- Parity status: Aligned for debug-only Gemini test-key fallback. Release builds keep the fallback empty or compiled out.

## Open parity checks

- Gemini live suggestion and rewrite flow: Pending emulator/simulator verification with a local test key.
- Gemini streaming and cancel behavior: Pending.
- Prompt shaping and response parsing: Pending cross-platform review.
- Rewrite actions: Pending cross-platform walkthrough.
- Rhyme context, prosody, trash, export, and persistence: Pending hardening pass.
