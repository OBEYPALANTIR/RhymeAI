# Repository Guidelines

## Project Overview

RhymeAI is a native songwriting assistant for writing lyrics, managing song projects, analyzing rhyme context, counting syllables, previewing stress/IPA, and generating AI rewrite/rhyme suggestions. The active app surfaces are the native Android Jetpack Compose app in `android/` and the native SwiftUI iOS app in `Writers Block/`. A desktop variant is planned, but the React/Vite web variant has been removed.

## Architecture & Data Flow

- **Android:** `MainViewModel.kt` is the single source of truth for editor, project, settings, AI provider/model, suggestions, rewrite previews, trash state, prosody previews, and save status. Compose screens read/write ViewModel `mutableStateOf` properties directly. `ProjectRepository.kt` persists projects, current editor state, trash state, and provider/model choice in Preferences DataStore, and routes API keys through `SecureKeyStore`/EncryptedSharedPreferences. `AIService.kt` dispatches to Gemini, OpenAI, Claude, or a local GGUF model.
- **iOS:** `Writers_BlockApp.swift` creates the `EditorViewModel` and SwiftData `ModelContainer`. `ContentView.swift` injects the ViewModel into SwiftUI via `@EnvironmentObject`. `EditorViewModel.swift` owns editor/project/settings state, debounced autosave, trash state, rhyme context, prosody previews, and rewrite flow. `AIService.swift` handles Gemini/OpenAI/Claude/Apple Intelligence calls.
- **Common flow:** lyrics + cursor position -> stanza/rhyme-context parsing -> section-aware prompt shaping -> AI suggestion/rewrite response -> UI preview/application -> debounced persistence. Android persists to DataStore; iOS persists projects with SwiftData and settings/API keys with `UserDefaults`.
- **Shared prosody assets:** `shared/pronunciation/` contains source fixtures and generated pronunciation data. `scripts/generate-pronunciation-assets.mjs` refreshes native assets for Android and iOS.

## Key Directories

- `android/app/src/main/kotlin/com/rhymeai/app/` — Android app source.
  - `ui/` — Compose screens/components/theme/navigation.
  - `service/` — cloud and local AI services.
  - `data/model/` — serializable app models/enums.
  - `data/repository/` — DataStore persistence.
  - `util/` — rhyme, syllable, prosody, and export helpers.
- `android/app/src/main/res/` — Android manifest resources, icons, XML file paths, values.
- `Writers Block/Writers Block/` — iOS SwiftUI app.
  - `Views/`, `Components/`, `ViewModels/`, `Services/`, `Models` map to their names.
- `Writers Block/Writers BlockTests/` — iOS unit tests using Swift Testing.
- `Writers Block/Writers BlockUITests/` — iOS UI/launch tests using XCTest.
- `shared/` — cross-platform pronunciation/prosody source data.
- `scripts/` — repository scripts for generating native shared assets.
- `DESIGN.md` — design tokens and product styling contract; consult before UI changes.

## Development Commands

Run Android commands from `android/`:

- `./gradlew :app:assembleDebug` — build a debug APK.
- `./gradlew :app:compileDebugKotlin` — fastest Kotlin compile check.
- `./gradlew :app:testDebugUnitTest` — run JVM unit tests.
- `./gradlew :app:lintDebug` — run Android lint for the debug variant.
- `./gradlew :app:connectedDebugAndroidTest` — run instrumented tests when a device or emulator is attached.

For iOS, use Xcode with `Writers Block/Writers Block.xcodeproj`, or first inspect schemes/destinations with:

- `xcodebuild -list -project "Writers Block/Writers Block.xcodeproj"`
- `xcrun simctl list devices`

Then run `xcodebuild build` or `xcodebuild test` with the confirmed scheme and simulator destination.

## Code Conventions & Common Patterns

- **General:** keep platform changes focused. Do not mix unrelated Android and iOS edits. Prefer direct code over new abstractions.
- **Android/Kotlin:** four-space indentation; `PascalCase` classes/composables; `camelCase` functions/properties. Compose UI is Material 3 and ViewModel-driven; async work uses `viewModelScope.launch`, repository/AI calls are `suspend`, and blocking/network work belongs on `Dispatchers.IO`. Repository reads use `Flow` and one-shot `.first()` when needed.
- **Android state/errors:** UI state is plain Compose mutable state on `MainViewModel`; error fields (`errorMessage`, `rewriteError`, `localModelError`) are set by caught exceptions and observed by UI. There is no Hilt/DI container; services are wired manually in the ViewModel.
- **Swift/iOS:** SwiftUI views end in `View`, services in `Service`, models are nouns. `EditorViewModel` uses `@Published`, `@MainActor`, async/await, cancellable `Task`s, and 1-second autosave debounce. SwiftUI dependencies flow through `@EnvironmentObject` and `@Environment(\.modelContext)`.
- **Rhyme context:** both platforms parse lyrics by line/stanza, skip or account for section headers, compute the active rhyme-scheme letter from cursor position, and use that context in prompts. Keep behavior aligned across Android and iOS when changing rhyme logic.
- **Prosody and syllables:** both platforms should consume the same pronunciation data and algorithmic rules so stress/IPA previews, syllable counts, and near/slant rhyme decisions stay aligned.
- **Persistence caution:** Android DataStore and iOS `UserDefaults` are not secure storage. API keys belong in `SecureKeyStore`/EncryptedSharedPreferences on Android and Keychain on iOS; do not regress them into plaintext preferences.

## Important Files

- `android/app/src/main/kotlin/com/rhymeai/app/MainActivity.kt` — Android entry and Compose setup.
- `android/app/src/main/kotlin/com/rhymeai/app/MainViewModel.kt` — Android app state machine.
- `android/app/src/main/kotlin/com/rhymeai/app/service/AIService.kt` — Android `AIService`, provider/model enums, prompts, streaming, and API parsing.
- `android/app/src/main/kotlin/com/rhymeai/app/data/repository/ProjectRepository.kt` — Android DataStore persistence.
- `android/app/build.gradle.kts` — Android SDKs, Kotlin/Compose config, dependencies, and generated `BuildConfig` version metadata.
- `Writers Block/Writers Block/Writers_BlockApp.swift` — iOS app entry and SwiftData container.
- `Writers Block/Writers Block/ViewModels/EditorViewModel.swift` — iOS central state, autosave, project/template/rewrite/trash/prosody logic.
- `Writers Block/Writers Block/Services/AIService.swift` — iOS multi-provider AI client and prompt parsing.
- `Writers Block/Writers Block/Services/ProsodyAnalyzer.swift` — iOS stress/IPA preview logic.
- `Writers Block/Writers Block/Views/EditorView.swift` — iOS main adaptive editor UI.
- `Writers Block/Writers Block.xcodeproj/project.pbxproj` — Xcode project settings.
- `shared/pronunciation/` — shared pronunciation fixtures and generated dictionary data.
- `scripts/generate-pronunciation-assets.mjs` — native pronunciation asset generator.

## Runtime/Tooling Preferences

- Use the Gradle wrapper in `android/`; do not assume a globally installed Gradle.
- Android uses Kotlin 2.3.20, Android Gradle plugin 8.9.1, Gradle 9.0.0, JVM 17, compile SDK 36, min SDK 26, target SDK 35.
- iOS is SwiftUI/SwiftData under Xcode; a shared `Writers Block` scheme is checked in, but still confirm schemes and simulator destinations before command-line builds.
- Android `android/local.properties` is local SDK configuration only. Runtime API keys are entered in-app and stored through encrypted storage. Never commit local secret files.
- Keep native asset generation in `scripts/`; do not reintroduce a root web package just to run the app.

## Testing & QA

- Android unit and instrumented tests live under `android/app/src/test/` and `android/app/src/androidTest/`.
- iOS unit tests in `Writers BlockTests/` use Swift Testing (`@Test`, `#expect`) and cover rhyme context/model-picker behavior.
- iOS UI tests in `Writers BlockUITests/` use XCTest/XCUIApplication and cover assistant sheet gestures, keyboard overlap, button state, launch, iPad layout, and launch performance.
- Add tests for risky behavior and regressions: rhyme-context parsing, autosave/persistence, trash restore/delete, provider/model selection, rewrite application, export formatting, prosody previews, and error handling. Do not add trivial getter tests.
- UI changes should be checked against `DESIGN.md`; include screenshots for PRs when visual behavior changes.

## RhymeAI UI Polish Pass — Agent Conventions

- Working branch: `chore/ui-polish-2026-05`.
- Design contract: `DESIGN.md` at the repository root.
- Required commands:
  - `./gradlew check`
  - `./gradlew lint`
  - `./gradlew detekt` — if configured; else skip silently.
  - `./gradlew spotlessApply` — if configured; else skip silently.
  - `./gradlew recordRoborazziDebug` — if Roborazzi is/becomes wired in.
  - `./gradlew connectedDebugAndroidTest` — only if an emulator is available.
- Commit messages: Conventional Commits with scopes `feat(ui)`, `fix(ui)`, `refactor(ui)`, `chore(ui)`, `test(ui)`, `style(ui)`.
- Anti-patterns:
  - Decorative blur outside chrome layers.
  - Glass on solid content.
  - Animations longer than 500 ms for utilitarian transitions.
  - Spring damping < 0.3 outside explicit celebratory feedback.
  - Custom buttons / switches / sliders duplicating stock Material 3.
  - Stacked elevation > 3 layers.
  - Gradients with > 3 stops.
  - Text on glass without heavier text weight or scrim support.
  - `contentDescription` equal to visible text.
  - Skipping edge-to-edge via `WindowCompat.setDecorFitsSystemWindows(window, false)`.
  - Mixing M2 fixed elevation/shadows on every card with M3 tonal surfaces.
