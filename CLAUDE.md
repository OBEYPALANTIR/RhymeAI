# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo shape

Three sibling implementations of one product. Product name = "Writers Block" (user-facing on native), package id = `com.rhymeai.app`, repo dir = `RhymeAI`. Same feature set, separate codebases — do not assume cross-tree refactors.

- `src/` — Vite + React 19 + TypeScript web app. Wrapped by Capacitor (`capacitor.config.ts`, `webDir: dist`) to produce the shipping Android web build alongside the native one. App is a single large `src/App.tsx` with localStorage persistence; only external service is `src/services/gemini.ts`.
- `android/` — native Kotlin + Jetpack Compose. Package `com.rhymeai.app`. MVVM: `MainActivity` → `MainViewModel` → `data/repository/ProjectRepository` + `service/{GeminiService,LocalModelService}` (`GeminiService` is the multi-provider entry point — Gemini, OpenAI, Claude, Local — despite the name). UI split into `ui/screens` (Welcome, Editor), `ui/components` (assistant panel, rhyme/syllable text, dialogs), `ui/theme`, `ui/navigation`. Models in `data/model/`.
- `Writers Block/` — native iOS SwiftUI (Xcode project `Writers Block.xcodeproj`). MVVM: `Views/` ← `ViewModels/EditorViewModel.swift` ← `Services/{AIService, LyricsExporter, RhymePhonetics, SyllableCounter}` and `Models/`. Liquid Glass styling via `Views/LiquidGlassSupport.swift`. Tests in `Writers BlockTests/`, UI tests in `Writers BlockUITests/`.

The three trees duplicate the same domain types (`SongProject`, `SongTemplate`, `RewriteAction`, `ExportFormat`, rhyme/syllable utilities). When changing a domain concept, check whether the parallel file in the other two trees needs the same change — there is no shared module.

## Design system

`DESIGN.md` at repo root is the canonical token sheet for all three platforms (colors, typography, rounded, spacing, motion, components). Check it before adjusting any visual constant. Platform notes inside: Android adapts to Material You dynamic color; iOS biases to translucent glass; both keep near-black canvas + indigo primary + serif display type. Rhyme/syllable color tokens are semantic, not decorative — do not reassign them.

## Commands

Web (run from repo root):

- `npm install`
- `npm run dev` — Vite on port 3000, host 0.0.0.0
- `npm run build` — production bundle into `dist/` (also feeds Capacitor)
- `npm run lint` — `tsc --noEmit`, no separate ESLint
- `npm run preview` — serve built bundle

Android (run from `android/`):

- `./gradlew :app:assembleDebug` — debug APK
- `./gradlew :app:compileDebugKotlin` — fastest correctness check
- `./gradlew :app:testDebugUnitTest` — JVM unit tests (under `android/app/src/test/`)
- Instrumented tests live under `android/app/src/androidTest/`

iOS:

- Open `Writers Block/Writers Block.xcodeproj` in Xcode, or
- `xcodebuild -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,name=iPhone 15' build`

Capacitor sync (after web build, when shipping the web inside the native shell): `npx cap sync android`.

## Config / secrets

- Web: `GEMINI_API_KEY` in `.env.local` (gitignored). Vite inlines it via `define: { 'process.env.GEMINI_API_KEY': ... }` in `vite.config.ts` — it ships to the client bundle, so do not put server-only keys there. Mitigate by setting tight per-key quotas in AI Studio; long-term, move calls behind a server proxy and drop the `define` inlining.
- Android: `GEMINI_API_KEY` in `android/local.properties` (gitignored). Read by `GeminiService`.
- iOS: configured at runtime via `Views/SettingsView.swift` (AI provider/key selection), not committed.
- `.env.example` lists keys; never write real values into it.
- `DISABLE_HMR=true` disables Vite file watching (used by AI Studio agent edits). Don't remove that branch in `vite.config.ts`.

## Conventions

- See `AGENTS.md` for repo-wide style/testing/commit rules. Highlights: keep commits focused per platform (don't mix web + Android + iOS in one commit); test names describe behavior (`generatesSyllableCountsForLyrics`); web/iOS/Android each follow native naming (PascalCase components, 4-space Kotlin, SwiftUI `*View` / `*Service`).
- Default branch is `main`; PRs target `main`. Work on the current branch unless asked otherwise. Prefer direct code over new abstractions, no new deps without justification, no emoji in code/commits.
- `app-icon.png` and Xcode project files may show as locally modified — check `git status` before staging.
