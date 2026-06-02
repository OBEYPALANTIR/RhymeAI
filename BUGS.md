# Bugs

## BUG-001: Android Gemini SDK default-model live gate was blocked

- Repro: Run a live Android Gemini request through `com.google.ai.client.generativeai:generativeai:0.7.0` using `AIModel.DEFAULT` (`gemini-3.5-flash`).
- Root cause: `android/local.properties` initially had no local Gemini test key, so the SDK request could not be executed honestly.
- Fix commit: `b789b73`.
- Re-verify: Passed on 2026-06-01 with `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest --tests 'com.rhymeai.app.service.GeminiSdkLiveGateTest'`. The Android SDK served `AIModel.DEFAULT`.

## BUG-002: iOS Gemini suggestion parsing could surface provider debris

- Repro: Parse provider-style suggestion output containing numbered lines, duplicate bullet lines, `model_response>` markers, prompt echo text, and overlong lines on both platforms.
- Root cause: Android suggestion parsing already normalized and filtered provider debris, while iOS parsed plain lines before the shared sanitizer/dedupe rules.
- Fix commit: `f2962da` (Android parity coverage), `8ee5269` (iOS parser hardening).
- Re-verify: Passed on 2026-06-02 with `./gradlew :app:testDebugUnitTest --tests 'com.rhymeai.app.service.AIServiceParsingTest'` and `xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:"Writers BlockTests"`.
