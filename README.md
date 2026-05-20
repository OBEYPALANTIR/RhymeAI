<div align="center">
<img width="1200" height="475" alt="GHBanner" src="https://github.com/user-attachments/assets/0aa67016-6eaf-458a-adb2-6e31a0763ed6" />
</div>

# RhymeAI

RhymeAI is an AI-assisted lyric writing studio. Sketch out a song, get rhyme suggestions tuned to your scheme and meter, watch syllable counts update as you write, and keep multiple song projects organized in one place. The app runs in the browser, on Android via Capacitor, and on iOS via the SwiftUI target in `Writers Block/`.

View the project in AI Studio: https://ai.studio/apps/98debd52-fa96-4102-8509-3709530633fc

## Features

- **Context-aware rhyme suggestions** — pass in the theme, current lyrics, and rhyme scheme to get line suggestions that match your meter.
- **Multi-provider AI on native** — Android and iOS let you pick Gemini, OpenAI, Claude, or an on-device Gemma model (GGUF, via llama.cpp on Android; Apple's FoundationModels on iOS). The web build uses Gemini.
- **Rhyme type control** — choose between Perfect, Near, and Slant rhymes.
- **Rhyme scheme highlighting** — AABB, ABAB, ABBA, or a custom scheme, with end-rhyme coloring across the lyric.
- **Live syllable counting** with per-syllable coloring for cadence checking.
- **Rewrite tools** — Rephrase, Harder Rhyme, and Punch Up actions on selected text (native).
- **Export** to plain text, project JSON (re-importable), a print-ready PDF lyric sheet, and `.lrc` (native).
- **Song templates** for Pop, Rap / Hip-Hop, Country, and Haiku starting points.
- **Project library** — auto-saved, multi-song workspace. Local storage on web; on-device storage on native.

## Project Layout

- `src/` — Vite + React 19 web app (`App.tsx`, `main.tsx`, `services/gemini.ts`).
- `android/` — Capacitor-backed Android shell with native Kotlin/Compose code in `app/src/main/kotlin/com/rhymeai/app/`.
- `Writers Block/` — native iOS SwiftUI target plus `Writers BlockTests/` and `Writers BlockUITests/`.
- `capacitor.config.ts` — shared Capacitor configuration.

See `AGENTS.md` for the full contributor guide.

## Run Locally (Web)

**Prerequisites:** Node.js 20+.

1. Install dependencies:
   ```
   npm install
   ```
2. Create `.env.local` and set your Gemini API key:
   ```
   GEMINI_API_KEY=your_key_here
   ```
   Get a key from [Google AI Studio](https://aistudio.google.com/app/apikey).
3. Start the dev server (port 3000):
   ```
   npm run dev
   ```

Other scripts:

- `npm run build` — production bundle into `dist/`.
- `npm run preview` — preview the production build.
- `npm run lint` — `tsc --noEmit` type check.

## Run on Android

From `android/`:

- `./gradlew :app:assembleDebug` — build a debug APK.
- `./gradlew :app:compileDebugKotlin` — fastest Kotlin compile check.
- `./gradlew :app:testDebugUnitTest` — JVM unit tests.

Set `GEMINI_API_KEY` in `android/local.properties` (do not commit it).

## Run on iOS

Open the `Writers Block` target in Xcode, or build from the command line with `xcodebuild` after confirming the scheme and simulator destination.

## Tech Stack

- **Web**: React 19, TypeScript, Vite 6, Tailwind CSS 4, `motion`, `lucide-react`, `syllable`, `@google/genai`.
- **Android**: native Kotlin + Jetpack Compose, Material 3 + dynamic color. AI through the official `GenerativeModel` SDK for Gemini and raw HTTP for OpenAI / Claude. On-device inference via llama.cpp over GGUF.
- **iOS**: native SwiftUI with Liquid Glass styling. Raw `URLSession` to Gemini / OpenAI / Anthropic REST plus Apple's `FoundationModels.SystemLanguageModel` as the "Local" provider.
- **Cross-platform shell**: Capacitor 8 wraps the web bundle for the Android web build alongside the native Compose target.

## Configuration & Secrets

Never commit API keys. The web app reads `GEMINI_API_KEY` from `.env.local`; the Android build reads it from `android/local.properties`; iOS stores provider keys at runtime via the in-app **Settings** screen. All of the dotfiles above are git-ignored.

Vite inlines `GEMINI_API_KEY` into the client bundle via `define` in `vite.config.ts`, so the key ships to the browser — restrict the key to tight per-app quotas in AI Studio and treat it as low-trust.
