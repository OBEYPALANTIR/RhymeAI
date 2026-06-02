# Known Issues

Current non-critical items remaining before final production-ready sign-off.

## Local GGUF inference smoke has current emulator evidence

- Status: Closed for scriptable Android local inference coverage.
- Scope: Android local provider.
- Evidence: on 2026-06-02,
  `LOCAL_GGUF_PATH="$PWD/artifacts/local-model-smoke/tinyllama-1.1b-chat-v0.6.q2_k.gguf" ANDROID_SERIAL=emulator-5554 ./scripts/android-local-model-smoke.sh`
  passed with an ignored 482143168-byte GGUF fixture. The run verified the GGUF
  header, built and installed the debug app plus test APK, pushed the model,
  loaded it through `LocalModelService`, and passed `LocalModelInstrumentedTest`
  with nonblank generation output.
- Note: keep the app-recommended Gemma downloads as the user-facing default;
  TinyLlama is only a smoke fixture.
- Next verification for future release candidates: attach an emulator/device and
  run:

```sh
LOCAL_GGUF_PATH=/absolute/path/to/model.gguf ./scripts/android-local-model-smoke.sh
```

## CloudKit needs live two-device verification

- Status: Open.
- Scope: iOS CloudKit sync.
- Evidence: static CloudKit readiness is scriptable through
  `scripts/ios-cloudkit-readiness.sh`; duplicate active/trash row behavior is
  unit-verified. The static gate passed on 2026-06-02, verifying the CloudKit
  container, entitlements, remote-notification background mode, build output,
  and trash conflict tests.
- Remaining live matrix: create, edit, concurrent edit, offline reconnect, delete
  propagation, trash restore, and permanent delete across two iCloud-signed-in
  simulators/devices.
- Next verification: execute `docs/CLOUDKIT_SYNC_CHECKLIST.md` on two
  iCloud-signed-in simulators/devices.

## OpenAI and Claude live happy paths need BYO keys

- Status: Open.
- Scope: Android and iOS provider services.
- Evidence: `ProviderLiveGateTest`, `ProviderLiveSmokeTests`, and
  `scripts/provider-live-smoke.sh` are wired to verify suggestions, rewrites,
  and streaming against the configured OpenAI and Claude models without printing
  keys. No-key/status/error behavior remains unit-verified.
- Next verification: run:

```sh
read -rsp "OpenAI test key: " OPENAI_TEST_KEY; echo
read -rsp "Claude or Anthropic test key: " CLAUDE_TEST_KEY; echo
export OPENAI_TEST_KEY CLAUDE_TEST_KEY
./scripts/provider-live-smoke.sh
```

`ANTHROPIC_TEST_KEY` may be used instead of `CLAUDE_TEST_KEY`; `OPENAI_TEST_MODEL`
and `CLAUDE_TEST_MODEL` may override the first configured provider models.

## Final release walkthrough evidence is captured

- Status: Closed for scriptable Android and iOS walkthrough coverage.
- Scope: Android and iOS.
- Evidence: Android and iOS release build gates exist and passed individually.
  iOS also has `scripts/ios-release-walkthrough.sh` for Release-configuration
  create/save/export surface/graceful no-key AI/rewrite/relaunch persistence.
  iOS also has a passing `scripts/ios-release-visual-walkthrough.sh` run
  (`20260602T081346Z`) for welcome, populated editor plus keyboard/UnBlock
  placement, export sheet, assistant panel, graceful no-key assistant error, and
  graceful no-key rewrite error screenshots. The 2026-06-02 screenshots were
  reviewed for blank, overlapping, clipped, and keyboard-obstructed layout
  failures.
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
