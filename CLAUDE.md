# CLAUDE.md

This file gives Claude Code the repo map for RhymeAI / Writers Block.

## What This Is

RhymeAI (product name "Writers Block") is a **native-first** songwriting
assistant: write lyrics, manage song projects, analyze rhyme context, count
syllables, preview stress/IPA, and get AI rewrite/rhyme suggestions. There are
two active app targets plus shared pronunciation tooling. A desktop variant is
planned but not started.

The old React/Vite web variant has been **removed**. Do not reintroduce a root
`package.json`, `src/`, Vite, or Capacitor files unless Tyler explicitly asks
for a web target again. The only Node usage left is `scripts/` for generating
shared pronunciation assets.

## Repo Shape

- `android/` — native Kotlin + Jetpack Compose app, package `com.rhymeai.app`.
- `Writers Block/` — native SwiftUI + SwiftData iOS app.
- `shared/pronunciation/` — CMU-backed pronunciation source + generated data.
- `scripts/` — Node tooling that regenerates native prosody assets.
- `DESIGN.md` — design tokens / product styling contract. **Read before any UI change.**
- `AGENTS.md` — longer-form contributor guide (conventions, QA, anti-patterns). Complements this file.
- `README.md` — short public overview.

## Architecture & Data Flow

Both platforms follow the same shape: a single ViewModel owns app state, Compose/
SwiftUI surfaces read and write it directly, a repository/persistence layer saves
it, and an `AIService` dispatches to cloud or on-device models.

Common flow: lyrics + cursor position → stanza/rhyme-context parsing →
section-aware prompt shaping → AI suggestion/rewrite response → UI preview/apply →
debounced persistence.

- **Android:** `MainViewModel.kt` is the single source of truth (editor, project,
  settings, provider/model, suggestions, rewrite previews, trash, prosody previews,
  save status) held as Compose `mutableStateOf`. `ProjectRepository.kt` persists to
  Preferences DataStore. No Hilt/DI — services are wired manually in the ViewModel.
- **iOS:** `Writers_BlockApp.swift` builds the `EditorViewModel` and a SwiftData
  `ModelContainer`; `ContentView.swift` injects the ViewModel via `@EnvironmentObject`.
  Projects persist with SwiftData; settings and API keys use `UserDefaults`.

## AI Providers & Models

Both platforms support **Gemini, OpenAI, Claude, and a Local/on-device model**.
Provider/model enums live in:

- Android: `service/AIService.kt` (`AIProvider`, `AIModel`).
- iOS: `Models/AIModels.swift` (`AIProvider`, `AIModel`).

The `LOCAL` provider runs on-device: Android via a GGUF model
(`service/LocalModelService.kt`, `io.github.ljcamargo:llamacpp-kotlin`), iOS via
Apple Foundation Models / Apple Intelligence. Keep the provider/model lists and
prompt behavior in **parity** across platforms when editing either.

## Android

Source root: `android/app/src/main/kotlin/com/rhymeai/app/`

- `MainActivity.kt` — entry point, Compose setup, edge-to-edge.
- `MainViewModel.kt` — central state machine.
- `service/AIService.kt` — provider/model enums, section-aware prompts, streaming
  Gemini/OpenAI/Claude calls, local-model prompt flow.
- `service/LocalModelService.kt` — GGUF local-model loading and generation.
- `data/repository/ProjectRepository.kt` — DataStore persistence (projects, trash,
  editor state, provider/model choice, API keys).
- `data/model/` — serializable models/enums: `SongProject`, `SongSection`,
  `SongTemplate`, `TrashedSongProject`, `RhymeScheme`, `RewriteAction`, `ExportFormat`.
- `ui/screens/` — `WelcomeScreen.kt`, `EditorScreen.kt`.
- `ui/components/` — `AssistantPanel.kt`, rewrite UI, suggestion cards, rhyme/syllable
  highlighting, dialogs (settings, projects, templates, export), `SafeArea.kt`.
- `ui/navigation/RhymeNavGraph.kt`, `ui/theme/` (Material 3 + `DesignTokens.kt`).
- `util/` — `ProsodyAnalyzer.kt`, `RhymePhonetics.kt`, `SyllableCounter.kt`, `LyricsExporter.kt`.
- `res/` — manifest resources, icons, splash drawable, `xml/file_paths.xml`, values.

Build/test from `android/` with the wrapper:

```sh
./gradlew :app:compileDebugKotlin         # fastest compile check
./gradlew :app:assembleDebug              # debug APK
./gradlew :app:testDebugUnitTest          # JVM unit tests
./gradlew :app:lintDebug                  # Android lint
./gradlew :app:connectedDebugAndroidTest  # instrumented tests (device/emulator required)
```

Toolchain: Kotlin 2.3.20, AGP 8.9.1, Gradle 9.0.0, JVM 17, compile SDK 36,
min SDK 26, target SDK 35. Use the wrapper — do not assume a global Gradle.

## iOS

Source root: `Writers Block/Writers Block/`

- `Writers_BlockApp.swift` — app entry + SwiftData container.
- `ContentView.swift` — injects ViewModel into the SwiftUI tree.
- `ViewModels/EditorViewModel.swift` — central state, 1-second debounced autosave,
  trash, rhyme context, prosody previews, rewrite flow (`@Published`, `@MainActor`).
- `Services/AIService.swift` — Gemini/OpenAI/Claude + Apple Intelligence local flow.
- `Services/ProsodyAnalyzer.swift`, `RhymePhonetics.swift`, `SyllableCounter.swift`, `LyricsExporter.swift`.
- `Models/` — `SongProject`, `SongTemplate`, `TrashedSongProject`, `RhymeModels`, `AIModels`, `RewriteAction`, `ExportFormat`.
- `Views/` — `EditorView`, `AssistantPanelView`, `ProjectsDrawerView`, `ProjectsView`,
  `TrashBinView`, `TemplatesView`, `SettingsView`, `WelcomeView`, `LiquidGlassSupport`.
- `Components/` — text views, rewrite chip bar/sheet, rhyme/syllable highlighting, suggestion/export.

Targets iOS 18.0, Swift 5.0, SwiftUI/SwiftData. No shared `.xcscheme` is checked
in, so **confirm scheme + simulator before any command-line build**:

```sh
xcodebuild -list -project "Writers Block/Writers Block.xcodeproj"
xcrun simctl list devices
# then: xcodebuild build/test with the confirmed scheme + -destination
```

## Shared Pronunciation Assets

- `shared/pronunciation/cmudict-rhymeai.tsv` — generated dictionary (alternate
  pronunciations grouped per normalized word: `word<TAB>variant|variant`).
- `shared/pronunciation/prosody-fixtures.json` — source fixtures.
- Regenerate native Android + iOS copies with:
  `node scripts/generate-pronunciation-assets.mjs`

Both platforms must consume the same pronunciation data and algorithmic rules so
stress/IPA previews, syllable counts, and near/slant rhyme decisions stay aligned.

## Testing

- Android unit tests: `android/app/src/test/...` (e.g. `util/ProsodyAnalyzerTest.kt`).
- Android instrumented/UI tests: `android/app/src/androidTest/...` (`NewFeatureUiTest.kt`).
- iOS unit tests: `Writers Block/Writers BlockTests/` (Swift Testing — `@Test`, `#expect`).
- iOS UI tests: `Writers Block/Writers BlockUITests/` (XCTest/XCUIApplication — assistant
  sheet gestures, keyboard overlap, launch, iPad layout, launch performance).

Add tests for risky/regression-prone behavior (rhyme-context parsing, autosave,
trash restore/delete, provider/model selection, rewrite application, export
formatting, prosody previews, error handling). Skip trivial getter tests.

## Working Rules

- **Native parity:** when changing prompts, rhyme context, prosody, trash, or
  provider/model behavior, keep Android and iOS aligned.
- **Keep edits platform-focused** — don't mix unrelated Android and iOS changes.
  Prefer direct code over new abstractions/DI.
- **Secrets out of source:** Android reads `GEMINI_API_KEY` from `android/local.properties`;
  iOS uses runtime settings. Never commit local secret files. DataStore /
  `UserDefaults` are not secure storage — don't expand API-key persistence without
  considering Keychain/Encrypted alternatives.
- **UI:** check `DESIGN.md` first. Material 3 / native components only — don't
  duplicate stock controls. See `AGENTS.md` for the full anti-pattern list.
- **Do not commit** screenshots, simulator captures, APKs, or anything under
  `artifacts/` (already gitignored).
- **Commits:** Conventional Commits with UI scopes like `feat(ui)`, `fix(ui)`,
  `refactor(ui)`, `chore`, `test(ui)` (see recent history).
</content>
