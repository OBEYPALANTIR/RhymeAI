# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

RhymeAI / "Writers Block" is **one product implemented three times** as parallel, independent apps that share behavior but no code:

- **Web** — Vite + React 19 + TypeScript at the repo root (`src/`, `index.html`, `vite.config.ts`).
- **Android** — Native Kotlin + Jetpack Compose under `android/app/src/main/kotlin/com/rhymeai/app/`.
- **iOS** — SwiftUI + SwiftData under `Writers Block/` (folder name contains a space — quote it in shell commands).

Capacitor config exists at the root (`capacitor.config.ts`, `@capacitor/*` deps) but the Android app under `android/` is a **standalone native Compose project**, not a Capacitor shell. Don't assume changes to the web app propagate to mobile.

When changing user-facing behavior (prompts, rhyme logic, suggestion sanitization), update **all three platforms** to keep them aligned — the git history shows explicit "align rhyme assistant behavior across mobile apps" commits. The web app is the simplest reference implementation.

## Common commands

Web (run from repo root):
- `npm install` — install deps.
- `npm run dev` — Vite dev server on port 3000, host `0.0.0.0`.
- `npm run build` — production bundle to `dist/`.
- `npm run lint` — TypeScript check (`tsc --noEmit`). There is no ESLint config; lint == typecheck.
- No web test runner is configured.

Android (run from `android/`):
- `./gradlew :app:assembleDebug` — debug APK.
- `./gradlew :app:compileDebugKotlin` — fastest Kotlin compile check.
- `./gradlew :app:testDebugUnitTest` — JVM unit tests (no tests present yet; the dirs `android/app/src/test/` and `android/app/src/androidTest/` are the conventional locations).

iOS: open `Writers Block/Writers Block.xcodeproj` in Xcode, or `xcodebuild` with an explicit scheme/destination. Test targets exist (`Writers BlockTests`, `Writers BlockUITests`) but currently contain only scaffolding.

## Configuration / secrets

- Web: `GEMINI_API_KEY` in `.env.local` (loaded by `vite.config.ts` via `loadEnv` and injected as `process.env.GEMINI_API_KEY`). `APP_URL` is also injected by AI Studio at runtime.
- Android: `GEMINI_API_KEY` in `android/local.properties` is read by `android/app/build.gradle.kts` and exposed via `BuildConfig.GEMINI_API_KEY`. Runtime keys for OpenAI/Claude are entered by the user in the Settings dialog and persisted via DataStore (`ProjectRepository`).
- iOS: API keys are entered at runtime through `SettingsView` and stored on-device; no build-time key.
- `local.properties`, `.env*` (except `.env.example`), and `.claude/` are gitignored.

## Architecture by platform

### Web (`src/App.tsx`)

A single-file React app. `App.tsx` owns essentially all state via `useState` + `localStorage` (keys prefixed `lyricist-*`). Persistence is **localStorage only** — no IndexedDB, no backend. The Gemini call lives in `src/services/gemini.ts` and is the only AI provider on web (unlike mobile, which is multi-provider). Tailwind v4 is wired through `@tailwindcss/vite`; styling lives in `src/index.css`. The `@/*` import alias resolves to the repo root (see `tsconfig.json` + `vite.config.ts`).

### Android (`com.rhymeai.app`)

Standard Compose MVVM:
- `MainActivity` hosts a single `MainViewModel` (`AndroidViewModel`) and a `NavHost` (`ui/navigation/RhymeNavGraph.kt`) with `WELCOME` and `EDITOR` routes. Dialogs (Projects, Templates, Settings) are rendered at the activity level driven by `viewModel.show*Dialog` flags.
- `service/AIService.kt` is the **provider-agnostic suggestion engine**. It dispatches across `AIProvider.{GEMINI, OPENAI, CLAUDE, LOCAL}`, builds the prompt once in `buildPrompt(...)`, then calls a provider-specific HTTP path (Gemini SDK, raw `HttpURLConnection` for OpenAI/Anthropic). The `LOCAL` path uses `LocalModelService` with `llamacpp-kotlin` for on-device GGUF Gemma inference, with its own `buildLocalPrompt` + `sanitizeLocalSuggestions` pipeline that strips Gemma chat markers, list prefixes, prompt echoes, and de-dupes against existing lyrics.
- `data/repository/ProjectRepository.kt` persists projects, API keys, and settings via Preferences DataStore. Models in `data/model/` are `@Serializable`.
- `AIModel` enum is the canonical list of selectable provider+model combinations; update it when adding/retiring models. `AIModel.DEFAULT` (currently `GEMINI_3_FLASH`) is used as the fallback.

### iOS (`Writers Block/`)

SwiftUI + SwiftData + ObservableObject:
- `Writers_BlockApp.swift` creates the `ModelContainer` (SwiftData) and a single `EditorViewModel` injected via `@EnvironmentObject`.
- `Services/AIService.swift` mirrors the Android `AIService` shape (same provider enum, same prompt structure). The local path uses Apple's **FoundationModels** framework and requires **iOS 26+** (gated with `if #available(iOS 26.0, *)`).
- `SongProject` is a `@Model` (SwiftData) — not a plain struct — so changes to its fields are a schema migration.
- `EditorView` branches on `horizontalSizeClass` to render an iPad split layout vs. iPhone single-column layout; the assistant panel is a persistent column on iPad and a sheet on iPhone.

## Cross-platform conventions

- **Prompt shape is the contract.** All three platforms build the same prompt: theme + lyrics + target rhyme line + rhyme type + rhyme scheme + current rhyme-scheme letter, with optional whole-song context. When tweaking prompting, change all three in the same PR.
- **Suggestion count**: 5 on web, 6 on mobile (`SUGGESTION_COUNT` / `suggestionCount`). Don't silently unify — check the existing constant before changing.
- **Rhyme scheme letter** drives whether to find a rhyme for an existing line or start a new sound; this logic lives client-side and decides what gets passed to the model.
- **Models retire frequently.** `AIModel` (Kotlin) and the iOS equivalent list specific model IDs (`gemini-3.1-pro-preview`, `claude-haiku-4-5-20251001`, etc.). When updating, change both mobile platforms together.
- **Don't mix platforms in one commit.** Commit history is conventional-style (`feat:`, `fix:`, `chore:`, `perf:`, `docs:`) and keeps web / Android / iOS changes separate even when implementing the same feature.

## Gotchas

- The iOS folder name `Writers Block` contains a space — always quote paths.
- `vite.config.ts` disables HMR when `DISABLE_HMR=true` (set by AI Studio to prevent flicker during agent edits). Don't "fix" this.
- `app-icon.png` and Xcode project files (`project.pbxproj`) are frequently locally modified by tooling; run `git status --short` before committing to avoid sweeping them in.
- The product is branded **RhymeAI** on web/Android (`appId: com.rhymeai.app`) but **Writers Block** on iOS (bundle/folder). Both names are intentional.
