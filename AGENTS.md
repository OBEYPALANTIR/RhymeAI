# RhymeAI Repository Guide

## Mission and Sources of Truth

RhymeAI (the shipped app name is Writers Block) is a native songwriting workspace for drafting lyrics, organizing songs, understanding rhyme and prosody, and requesting AI-assisted suggestions or rewrites without taking authorship away from the writer.

- Read `docs/PRODUCT_DNA.md` before greenfield planning, architecture selection, major UX or design-system decisions, positioning or launch work, monetization or growth work, and cross-product standardization. An unrelated small fix does not require loading it.
- Read `DESIGN.md` before changing appearance, layout, motion, typography, components, or responsive behavior.
- Read `PARITY.md` before changing behavior present on Android and iOS.
- Read `README.md` and the relevant script before running a build, test, release, or live-provider gate.
- Treat this checkout as an independent working copy. Inspect its branch, status, files, and tool state; never assume another RhymeAI checkout is synchronized.

## One Coordinated Team

Work as one coordinated product team, even when tasks run in parallel. Name one owner for each file or responsibility, share discoveries that affect another platform, and reconcile cross-platform contracts before declaring completion. Preserve unrelated and uncommitted work. Do not revert, reformat, commit, push, publish, upload, or change release/signing state unless the task explicitly authorizes it.

Lead with the smallest complete change. Investigate the real mechanism, test the affected user journey, and report observed evidence rather than inferred success. A platform-specific implementation is acceptable only when the platform requires it; user-visible behavior should remain aligned.

Select only the relevant product, iOS, Android, AI/data, design/accessibility, QA/performance, security/privacy, release, marketing/growth, or advisory perspectives. Activate marketing and growth only for user-facing, onboarding, monetization, analytics, launch, store, or positioning work, and never invent proof or capabilities.

## Native Product Architecture

- Android lives in `android/` and uses Kotlin, Jetpack Compose, Material 3, a ViewModel-owned state model, coroutines, Preferences DataStore, and native services.
- iOS lives in `Writers Block/` and uses Swift, SwiftUI, SwiftData, CloudKit readiness, `EditorViewModel`, async/await, and native services.
- Repository pins are Kotlin 2.3.20, Android Gradle Plugin 8.9.1, Gradle 9.0.0 via the wrapper, JVM 17, compile SDK 36, min SDK 26, target SDK 35, Swift 5, and iOS 18.0. Preserve them unless an upgrade is explicitly requested.
- The native source includes `android/benchmark/` and the vendored llama XCFramework contract in `Writers Block/Frameworks/README.md`; validate those assets in the working checkout rather than borrowing another checkout’s evidence.
- `shared/pronunciation/` and `scripts/generate-pronunciation-assets.mjs` define shared pronunciation/prosody assets.
- `finetune/` contains local-model data, evaluation, training, and export work. Do not present an evaluation artifact as a shipped model or a model file as passing quality evidence.
- The removed React/Vite client is not an active target. Native Mac work is maintained separately in PR #38 and is unfinished; it is not included in this mobile integration or a shipped parity target.

The common writing flow is lyrics and cursor context, then stanza/rhyme parsing, prompt shaping, provider or local inference, suggestion/rewrite review, explicit application, and persistence. Keep section headers, rhyme targets, syllables, stress/IPA, error mapping, export behavior, trash retention, and provider/model choices aligned where both apps expose them.

## State, Privacy, and Security Boundaries

- Android stores projects and non-secret settings in Preferences DataStore. API keys and sync passphrases belong behind `SecureKeyStore` in `EncryptedSharedPreferences`, backed by Android Keystore.
- iOS stores projects in SwiftData and non-secret preferences/provider selections in `UserDefaults`. API keys, OAuth tokens, and backup secrets belong in Keychain-backed stores.
- `UserDefaults` is correct for non-secret preferences; it is never the destination for credentials. Legacy plaintext-key code exists only to migrate values into secure storage and remove the plaintext copy.
- Keep user lyrics local by default. Make network/provider use legible and intentional. Never log keys, tokens, passphrases, full provider bodies, private lyrics, or model download credentials.
- Keep release builds free of embedded test keys. Respect network security, backup exclusions, file sharing boundaries, and least-privilege platform entitlements.

## Implementation Conventions

- Match the surrounding language and architecture; avoid introducing a new dependency or abstraction for a local change.
- Android state normally belongs in `MainViewModel`; blocking/network work belongs on `Dispatchers.IO`; repository/AI calls are `suspend`; Compose UI observes explicit state and exposes meaningful semantics.
- iOS state normally belongs in `EditorViewModel`; UI work stays on `@MainActor`; cancellable work uses `Task`; SwiftUI dependencies flow through the environment or explicit initializers.
- Preserve the one-second autosave behavior and test persistence across relaunch when changing editor or project state.
- Keep shared prompt and parsing contracts deterministic. Provider-specific exceptions must be documented and tested on both sides of the boundary.
- Comments should explain constraints that code cannot express, not narrate obvious operations.

## Build and Test Commands

Run commands from this checkout unless a command changes directory explicitly.

```sh
./scripts/verify.sh
```

The default harness builds and tests Android and builds/tests iOS. Override its confirmed simulator with `IOS_DESTINATION`; use `SKIP_ANDROID=1` or `SKIP_IOS=1` only for an intentionally scoped run and report that reduced scope.

```sh
cd android
./gradlew :app:assembleDebug
./gradlew :app:compileDebugKotlin
./gradlew :app:testDebugUnitTest
./gradlew :app:lintDebug
./gradlew :app:connectedDebugAndroidTest
```

```sh
xcodebuild -list -project "Writers Block/Writers Block.xcodeproj"
xcrun simctl list devices available
xcodebuild build -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination '<confirmed destination>'
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination '<confirmed destination>' -only-testing:"Writers BlockTests"
```

Regenerate shared native pronunciation assets with `node scripts/generate-pronunciation-assets.mjs`, then review both platform outputs and run their affected tests.

## End-to-End and Release Gates

- Android: `./scripts/android-release-smoke.sh`, `./scripts/android-release-walkthrough.sh`, and `./scripts/android-release-visual-audit.sh`.
- iOS: `./scripts/ios-release-smoke.sh`, `./scripts/ios-release-walkthrough.sh`, `./scripts/ios-release-visual-walkthrough.sh`, and `./scripts/ios-release-visual-audit.sh`.
- Live dependencies: `./scripts/provider-live-smoke.sh`, `LOCAL_GGUF_PATH=/absolute/model.gguf ./scripts/android-local-model-smoke.sh`, and `./scripts/ios-cloudkit-readiness.sh`.
- Overall readiness: `./scripts/final-signoff-status.sh`. A recorded or static gate does not substitute for a required live provider, device, inference, sync, signing, store, or upload observation.

Release scripts may build signed artifacts using existing local configuration. Changing certificates, entitlements, provisioning, keystores, store records, versioning, or external release state requires explicit approval. Publishing, uploading, or destructive cleanup always requires action-time confirmation and an exact target inventory.

For time-sensitive iOS, Android, App Store, Google Play, privacy, SDK, or publishing requirements, verify the current official Apple or Google documentation at execution time instead of freezing a volatile rule here.

## Accessibility and Visual QA

For user-interface work, verify the real surface on a phone first, then the relevant tablet/iPad size. Exercise portrait and landscape where supported, keyboard shown/hidden, light/dark authored appearances, large text or font scale, screen-reader labels, focus order, touch targets, contrast, increased contrast/transparency settings, and reduced motion. Preserve safe areas and gesture/navigation bars. Screenshots support visual review but do not prove interaction, accessibility, persistence, or inference.

## Completion and Evidence

Add focused regression tests for rhyme context, prosody, provider parsing/errors, cancellation, autosave, trash, secure migration, export, or adaptive UI when those behaviors change. Do not add tests that only repeat implementation details.

Every completion report must name:

1. the exact user scenario exercised;
2. the exact invocation and checkout;
3. the binary observable that passed or failed (exit code, process alive, UI state, persisted value, artifact signature/hash, or live response);
4. the captured artifact path (log, screenshot, report, test result, APK/AAB, archive, or checksum);
5. the target environment and any skipped or blocked dimension.

Do not say “parity,” “release-ready,” “accessible,” “secure,” “live,” or “shipped” from a compile alone. Update `PARITY.md`, release notes, or sign-off records only with current evidence and keep known gaps explicit.
