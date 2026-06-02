# Known Issues

Current non-critical items remaining before final production-ready sign-off.

## Local GGUF inference smoke needs a model file

- Status: Open.
- Scope: Android local provider.
- Evidence: `scripts/android-local-model-smoke.sh` and `LocalModelInstrumentedTest`
  are wired, but no local `.gguf` file was present during the latest pass.
- Next verification: attach an emulator/device and run:

```sh
LOCAL_GGUF_PATH=/absolute/path/to/model.gguf ./scripts/android-local-model-smoke.sh
```

## CloudKit needs live two-device verification

- Status: Open.
- Scope: iOS CloudKit sync.
- Evidence: static CloudKit readiness is scriptable through
  `scripts/ios-cloudkit-readiness.sh`; duplicate active/trash row behavior is
  unit-verified.
- Remaining live matrix: create, edit, concurrent edit, offline reconnect, delete
  propagation, trash restore, and permanent delete across two iCloud-signed-in
  simulators/devices.
- Next verification: run `./scripts/ios-cloudkit-readiness.sh`, then execute
  `docs/CLOUDKIT_SYNC_CHECKLIST.md`.

## Final release walkthrough is pending

- Status: Open.
- Scope: Android and iOS.
- Evidence: Android and iOS release build gates exist and passed individually.
  iOS also has `scripts/ios-release-walkthrough.sh` for Release-configuration
  create/save/export surface/graceful no-key AI/rewrite/relaunch persistence.
  Android has `scripts/android-release-walkthrough.sh` for a passing minified
  release APK create/save/export surface/graceful no-key
  suggestion/force-stop/relaunch persistence run.
  Android also has a passing `scripts/android-release-live-gemini.sh` run for
  release runtime key entry plus live Gemini suggestion/rewrite preview coverage.
  iOS has a passing `scripts/ios-release-visual-audit.sh` run for Release
  light/dark iPhone and iPad screenshot capture; the 2026-06-02 screenshots were
  reviewed for blank, overlapping, and launch-blocking layout failures.
  Android has a passing `scripts/android-release-visual-audit.sh` run for Release
  phone light/dark/large-font screenshots plus populated editor, assistant
  panel, and export sheet screenshots; the 2026-06-02 screenshots were reviewed
  for blank, overlapping, keyboard-obstructed, and launch-blocking layout
  failures. The script now classifies real phone/tablet targets from screen size
  and density, and a 2026-06-02 tablet-profile run on a 2560x1600 / 320 dpi
  Android 36 emulator produced reviewed tablet-labeled evidence for the same
  surfaces.
- Remaining walkthrough: iOS still needs any remaining human-only release
  walkthrough beyond the captured launch screenshots.
