<div align="center">
<img width="1200" height="475" alt="GHBanner" src="https://github.com/user-attachments/assets/0aa67016-6eaf-458a-adb2-6e31a0763ed6" />
</div>

# RhymeAI

RhymeAI is an AI-assisted lyric writing studio. Sketch out a song, get rhyme suggestions tuned to your scheme and meter, watch syllable counts update as you write, and keep multiple song projects organized in one place. The app runs in the browser, on Android via Capacitor, and on iOS via the SwiftUI target in `Writers Block/`.

View the project in AI Studio: https://ai.studio/apps/98debd52-fa96-4102-8509-3709530633fc

## Features

- **Context-aware rhyme suggestions** powered by Gemini — pass in the theme, current lyrics, and rhyme scheme, and get five line suggestions that match your meter.
- **Rhyme type control** — choose between Perfect, Near, and Slant rhymes.
- **Rhyme scheme highlighting** — AABB, ABAB, ABBA, or a custom scheme, with end-rhyme coloring across the lyric.
- **Live syllable counting** with per-syllable coloring for cadence checking.
- **Song templates** for Pop, Rap / Hip-Hop, Country, and Haiku starting points.
- **Project library** — auto-saved, multi-song workspace stored in local storage.

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

- React 19, TypeScript, Vite 6, Tailwind CSS 4
- `@google/genai` (Gemini) for rhyme generation
- `syllable` for syllable counts
- `motion` for animations, `lucide-react` for icons
- Capacitor 8 for the Android shell; native SwiftUI for iOS

## Configuration & Secrets

Never commit API keys. The web app reads `GEMINI_API_KEY` from `.env.local`; the Android build reads it from `android/local.properties`. Both files are git-ignored.
