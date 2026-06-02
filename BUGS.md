# Bugs

## BUG-001: Android Gemini SDK default-model live gate was blocked

- Repro: Run a live Android Gemini request through `com.google.ai.client.generativeai:generativeai:0.7.0` using `AIModel.DEFAULT` (`gemini-3.5-flash`).
- Root cause: `android/local.properties` initially had no local Gemini test key, so the SDK request could not be executed honestly.
- Fix commit: Pending.
- Re-verify: Passed on 2026-06-01 with `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest --tests 'com.rhymeai.app.service.GeminiSdkLiveGateTest'`. The Android SDK served `AIModel.DEFAULT`.
