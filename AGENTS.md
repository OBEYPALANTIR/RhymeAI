# Repository Guidelines

## Project Structure & Module Organization

RhymeAI is a mixed web, Android, and iOS repository. The root Vite/React app lives in `src/`, with entry points in `src/main.tsx` and `src/App.tsx`; shared styling is in `src/index.css`. Capacitor configuration is in `capacitor.config.ts`. The native Android app is under `android/app/src/main/kotlin/com/rhymeai/app/`, with Compose UI in `ui/`, services in `service/`, models in `data/model/`, and resources in `android/app/src/main/res/`. The iOS SwiftUI app is nested under `Writers Block/`, with tests in `Writers BlockTests/` and UI tests in `Writers BlockUITests/`.

## Build, Test, and Development Commands

Run root web commands from this directory:

- `npm install` installs Node dependencies from `package-lock.json`.
- `npm run dev` starts Vite on port 3000 for local web work.
- `npm run build` creates the production web bundle in `dist/`.
- `npm run lint` runs TypeScript checking with `tsc --noEmit`.

Run Android commands from `android/`:

- `./gradlew :app:assembleDebug` builds a debug APK.
- `./gradlew :app:compileDebugKotlin` is the fastest Kotlin compile check.
- `./gradlew :app:testDebugUnitTest` runs JVM unit tests when present.

Use Xcode for the `Writers Block` iOS target, or run `xcodebuild` after confirming the scheme and simulator destination.

## Coding Style & Naming Conventions

Use TypeScript and React function components in the web app. Keep UI files and exported components in `PascalCase`. Kotlin uses four-space indentation, `PascalCase` for classes/composables, and `camelCase` for functions, properties, and locals. Swift follows standard SwiftUI naming: views end in `View`, models are nouns, and services end in `Service`. Prefer direct code over new abstractions.

## Testing Guidelines

Add tests for risky behavior and regressions, not trivial getters. Put Android unit tests under `android/app/src/test/` and instrumented tests under `android/app/src/androidTest/`. Keep Swift tests in the existing `Writers BlockTests/` and UI flows in `Writers BlockUITests/`. Name tests after behavior, for example `generatesSyllableCountsForLyrics`.

## Commit & Pull Request Guidelines

Recent history uses concise conventional-style commits such as `fix: Keep editor text visible above keyboard` and `feat: Search saved songs`. Keep commits focused and do not mix unrelated Android, web, and iOS changes. PRs should state what changed, how it was tested, and include screenshots for UI work.

## Security & Configuration

Do not commit secrets. The web app expects `GEMINI_API_KEY` in `.env.local`; Android reads `GEMINI_API_KEY` from `android/local.properties`. Check `git status --short --branch` before pulls or commits, especially because generated app icons and Xcode project files may already be locally modified.
