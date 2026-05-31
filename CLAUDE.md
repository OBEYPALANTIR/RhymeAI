# CLAUDE.md

This file gives Claude Code the repo map for RhymeAI / Writers Block.

## Repo Shape

RhymeAI is now native-first. The active targets are:

- `android/` — native Kotlin + Jetpack Compose app, package `com.rhymeai.app`.
- `Writers Block/` — native SwiftUI iOS app.
- `shared/pronunciation/` and `scripts/` — shared CMU-backed prosody assets and generation tooling.

The old React/Vite web variant has been removed. Do not reintroduce root `package.json`, `src/`, Vite, or Capacitor files unless Tyler explicitly asks for a web target again.

## Android

Android state is centered in `android/app/src/main/kotlin/com/rhymeai/app/MainViewModel.kt`.

Important Android files:

- `service/AIService.kt` — provider/model enums, section-aware prompts, streaming Gemini/OpenAI/Claude calls, local-model prompt flow.
- `service/LocalModelService.kt` — GGUF local-model loading and generation.
- `data/repository/ProjectRepository.kt` — DataStore persistence for projects, trash, editor state, provider/model choice, and API keys.
- `ui/screens/EditorScreen.kt` and `ui/components/AssistantPanel.kt` — editor, assistant sheet, rewrite and suggestion UI.
- `util/ProsodyAnalyzer.kt`, `RhymePhonetics.kt`, `SyllableCounter.kt` — shared pronunciation-driven analysis.

Run Android commands from `android/` using the wrapper:

```sh
./gradlew :app:assembleDebug
./gradlew :app:compileDebugKotlin
./gradlew :app:testDebugUnitTest
./gradlew :app:lintDebug
./gradlew :app:connectedDebugAndroidTest
```

## iOS

iOS state is centered in `Writers Block/Writers Block/ViewModels/EditorViewModel.swift`.

Important iOS files:

- `Services/AIService.swift` — provider/model enums, section-aware prompts, streaming Gemini/OpenAI/Claude calls, Apple Intelligence local flow.
- `Services/ProsodyAnalyzer.swift`, `RhymePhonetics.swift`, `SyllableCounter.swift` — pronunciation-driven analysis.
- `Views/EditorView.swift`, `Views/AssistantPanelView.swift`, `Views/ProjectsDrawerView.swift`, `Views/TrashBinView.swift` — main app surfaces.

Before command-line iOS builds, confirm schemes and simulator destinations:

```sh
xcodebuild -list -project "Writers Block/Writers Block.xcodeproj"
xcrun simctl list devices
```

## Working Rules

- Preserve native parity when changing prompts, rhyme context, prosody, trash, or provider/model behavior.
- Keep API keys out of source. Android stores runtime keys through `SecureKeyStore`/EncryptedSharedPreferences; iOS stores runtime keys in Keychain. `android/local.properties` is local SDK configuration only.
- Check `DESIGN.md` before UI changes.
- Do not commit screenshots, simulator captures, APKs, or files under `artifacts/`.
