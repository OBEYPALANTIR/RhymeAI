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

## BUG-003: Empty Gemini suggestion streams could finish silently

- Repro: Let a provider suggestion stream complete without emitting any usable suggestion lines.
- Root cause: Both ViewModels cleared suggestions and stopped loading, but did not surface an error when the stream completed empty.
- Fix commit: `cccc3d3` (Android), `d6ab06b` (iOS).
- Re-verify: Passed on 2026-06-02 with `./gradlew :app:testDebugUnitTest --tests 'com.rhymeai.app.service.AIServicePromptTest' --tests 'com.rhymeai.app.service.AIServiceParsingTest'` and `xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:"Writers BlockTests"`.

## BUG-004: iOS rewrite chip look-up tap target could fall through

- Repro: In the iOS editor, select a single word, wait for the rewrite chip bar, then tap near the edge of the look-up glyph.
- Root cause: The button's visual frame was 44pt, but only the small glyph region participated in hit testing, so edge taps could pass through to the lyric editor.
- Fix commit: `32d3a81`.
- Re-verify: Passed on 2026-06-02 with `xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:"Writers BlockUITests/Writers_BlockUITests/testSingleWordLookUpOpensInspector"`.

## BUG-005: iOS UnBlock button could overlap the rewrite chip bar

- Repro: On iPhone, force the selection rewrite bar visible and check whether the floating UnBlock button remains behind it.
- Root cause: The assistant floating button hid for active rewrites and modals, but not for the selection rewrite chip bar, so two bottom-anchored controls could compete for the same space.
- Fix commit: `32d3a81`.
- Re-verify: Passed on 2026-06-02 with `xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:"Writers BlockUITests/Writers_BlockUITests/testUnBlockButtonHidesWhenRewriteBarVisible"`.

## BUG-006: iOS LRC/PDF exports stripped leading lyric indentation

- Repro: Export lyrics containing leading spaces or tabs in LRC/PDF format on both platforms.
- Root cause: Android trimmed only trailing whitespace for formatted exports, while iOS trimmed both leading and trailing spaces/tabs before LRC/PDF rendering.
- Fix commit: `76fe468` (Android parity coverage), `9e4ad12` (iOS export alignment).
- Re-verify: Passed on 2026-06-02 with `./gradlew :app:testDebugUnitTest --tests 'com.rhymeai.app.util.LyricsExporterTest'` and `xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:"Writers BlockTests/LyricsExporterTests"`.

## BUG-007: Android sync could let stale trash delete restored projects

- Repro: Merge a local active project restored at `updatedAt=300` with a remote trash entry for the same project deleted at `deletedAt=200`.
- Root cause: `SyncMerger` merged active projects and trash independently, then always removed active projects whose IDs appeared in trash instead of comparing the active update timestamp against the trash deletion timestamp.
- Fix commit: `519daf8`.
- Re-verify: Passed on 2026-06-02 with `./gradlew :app:testDebugUnitTest --tests 'com.rhymeai.app.data.sync.SyncMergerTest'`.
