# Release Notes

## Writers Block / RhymeAI 0.2 Readiness Draft

This draft tracks the current production-readiness branch. It is not final until
the full release walkthrough and remaining known issues are closed.

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
- Android local GGUF inference has a dedicated emulator/device smoke gate that
  requires a real model path.
- iOS CloudKit readiness has a scriptable static gate and a live two-device
  checklist for final sync verification.

## Verification Commands

```sh
./scripts/verify.sh
./scripts/android-release-smoke.sh
./scripts/android-release-walkthrough.sh
./scripts/android-release-live-gemini.sh
./scripts/android-release-visual-audit.sh
./scripts/ios-release-smoke.sh
./scripts/ios-release-walkthrough.sh
./scripts/ios-release-visual-audit.sh
./scripts/ios-cloudkit-readiness.sh
./scripts/ios-local-provider-smoke.sh
LOCAL_GGUF_PATH=/absolute/path/to/model.gguf ./scripts/android-local-model-smoke.sh
```

## Remaining Before Final Sign-Off

- Run Android local GGUF smoke with an actual model file.
- Run CloudKit live two-simulator/device matrix with an iCloud account.
- Finish any remaining human-only release walkthrough beyond the captured
  Android phone/tablet and iOS screenshots before moving non-blocking friction into
  `KNOWN_ISSUES.md`.
