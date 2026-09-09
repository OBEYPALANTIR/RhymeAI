# Release Notes

## Writers Block for iOS 1.0 (6) — TestFlight candidate

This candidate combines the current iOS repairs for TestFlight acceptance.
App Store Connect processing and tester availability establish distribution
status; a successful archive alone does not. Android release status is tracked
separately.

### Changes to try

- Approve cloud AI sharing separately for selected context and the whole song.
  Changing provider or expanding the shared scope requires the matching consent.
- Choose Perfect, Near, or Slant rhymes. Suggestions must match the selected tier;
  an unmatched response shows a no-match message instead of unrelated filler.
- Use a local GGUF model for writing and synonym suggestions. Saved custom model
  selections persist across relaunches.
- Undo and redo edits, select text containing emoji, and switch songs while an
  autosave or rewrite is pending. These paths preserve the intended song and
  selection.
- Try the appearance and analysis styles on iPhone and iPad, including large text,
  the keyboard, rewrite controls, and the iPad projects sidebar.
- Restore or remove trashed songs and recordings. Recording cleanup rejects paths
  outside its storage directory; backup and sync validate restored metadata and
  keep provider API keys in the Keychain.

### Validation status

The composed source passed 329 unit tests with 6 runtime skips and no failures.
Four skips concern unavailable Apple Intelligence generation on the simulator;
two require OpenAI or Claude credentials. Two additional live Gemini tests were
explicitly excluded from selection. These results do not establish live cloud
provider availability or local GGUF generation quality.

Release simulator and signed device archives build successfully. Independent
phone/iPad acceptance, actual local GGUF inference, final review, and processed
TestFlight delivery must be checked against the candidate before distribution.
Live two-device CloudKit sync with an
iCloud account remains unverified in this candidate.

## Historical Writers Block / RhymeAI 0.2 Readiness Draft

The following historical draft predates the iOS 1.0 (6) candidate. Its command
results and remaining-work list do not describe current candidate acceptance.

## Highlights

- Native Android and iOS songwriting surfaces remain enabled: Gemini, OpenAI,
  Claude, Local provider selection, project persistence, trash, export, rhyme
  context, syllable, stress, and IPA previews.
- Gemini live paths are verified for suggestion, rewrite, streaming, cancellation,
  invalid-key handling, blocked responses, and offline/timeout failure messaging.
- Android release builds are minified, can be signed through ignored
  `android/keystore.properties`, and have a release smoke gate for signing,
  release artifact key scanning, install, and launch.
- Android Release visual audit captures and reviews phone and tablet
  light/dark/large-font launch screenshots plus populated editor, assistant, and
  export surfaces.
- iOS Release builds have a signed simulator build/launch smoke gate, archive
  creation, and release binary key scanning.
- iOS Release visual audit captures and reviews light/dark iPhone and iPad
  simulator screenshots.
- iOS Release visual walkthrough captures and reviews welcome, populated editor,
  export sheet, assistant panel, no-key assistant error, and no-key rewrite error
  screenshots.
- Cross-platform UI polish keeps Android Material and iOS Liquid Glass surfaces
  consistent with the shipped design tokens, including recordings search,
  transient error feedback, motion timing, and warning color treatment.
- Android local GGUF inference has a dedicated emulator/device smoke gate with
  passing evidence from a real ignored GGUF fixture.
- OpenAI and Claude happy paths have a BYO-key cross-platform provider smoke
  gate for suggestions, rewrites, and streaming.
- iOS CloudKit readiness has a scriptable static gate and a live two-device
  checklist for final sync verification.
- The latest final sign-off command evidence is recorded in
  `docs/FINAL_SIGNOFF_STATUS.md`.

## Verification Commands

```sh
./scripts/verify.sh
./scripts/final-signoff-status.sh
./scripts/android-release-smoke.sh
./scripts/android-release-walkthrough.sh
./scripts/android-release-live-gemini.sh
./scripts/android-release-visual-audit.sh
./scripts/ios-release-smoke.sh
./scripts/ios-release-walkthrough.sh
./scripts/ios-release-visual-walkthrough.sh
./scripts/ios-release-visual-audit.sh
./scripts/ios-cloudkit-readiness.sh
./scripts/ios-local-provider-smoke.sh
./scripts/provider-live-smoke.sh # requires exported OPENAI_TEST_KEY and CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY
LOCAL_GGUF_PATH=/absolute/path/to/model.gguf ./scripts/android-local-model-smoke.sh
```

## Remaining Before Final Sign-Off

- Run CloudKit live two-simulator/device matrix with an iCloud account.
- Run `scripts/provider-live-smoke.sh` with supplied OpenAI and Claude keys.
