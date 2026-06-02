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
  Android has `scripts/android-release-walkthrough.sh` for minified release APK
  create/save/export surface/graceful no-key suggestion/force-stop/relaunch
  persistence, but it still needs an attached emulator/device run.
- Remaining walkthrough: Android still needs the release walkthrough run on a
  device plus live Gemini suggestion/rewrite coverage on a signed release build,
  including light/dark and phone/tablet coverage where available. iOS still
  needs the broader human light/dark and iPad release pass.
