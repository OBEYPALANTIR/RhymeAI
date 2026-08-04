# RhymeAI Monochrome and Paper Appearance Design

Date: 2026-07-11
Status: Approved for implementation by the user's request to finish the UI work
Platforms: Android and iOS

## Problem

The shipped black-and-white WB icon is crisp, editorial, and distinctive, while the app UI still uses indigo and purple chrome, Android wallpaper-derived colors, and blue-gray iOS glass. The app therefore feels visually disconnected from its icon and less focused than the lyric-writing experience should feel.

## Goals

- Make the WB icon's black-and-white visual language the default app identity.
- Offer paper-and-pencil alternatives without sacrificing readability or native behavior.
- Keep Android and iOS visually aligned while using each platform's native controls and accessibility behavior.
- Preserve color where it communicates rhyme, syllable count, success, warning, or error state.
- Keep appearance switching immediate, persistent, offline, and inexpensive during typing and animation.

## Non-goals

- Reworking navigation, editor behavior, assistant behavior, project storage, or AI features.
- Replacing native controls with decorative hand-drawn replicas.
- Adding bundled handwriting fonts, raster paper textures, or animated grain.
- Making analysis colors monochrome; their color is functional rather than decorative.

## Product Decision

The app exposes one Appearance control with three mutually exclusive styles:

1. **Ink Editorial** is the default. It uses paper white, near-black ink, grayscale surfaces, thin rules, square-to-soft geometry, serif song identity, and solid black primary actions. It is the closest match to the app icon.
2. **Paper Notebook** uses warm ivory paper, graphite text, faint static fibers and optional lyric-area rules, outlined controls, and the existing pencil/scribble motif. Texture remains behind content and never reduces text contrast.
3. **Graphite Night** uses soft black paper, chalk-white text and actions, grayscale raised surfaces, and subtle static grain. It is the low-glare dark counterpart to Ink Editorial.

Missing or invalid stored values resolve to Ink Editorial. Existing installs therefore adopt the new brand direction on first launch after the update. Users who prefer a dark workspace can select Graphite Night.

## Shared Visual Rules

- Ordinary chrome, navigation, cards, selected states, and primary actions use only neutral ink and paper tones.
- Rhyme, syllable, success, warning, and error colors remain semantic exceptions.
- Song titles and major writing identity continue to use system serif. Lyrics and controls continue to use native system sans. Technical metadata remains monospaced.
- Paper texture is procedural and static. It is composed once from low-opacity gradients or cached drawing primitives; it does not redraw noise on every frame.
- The existing pencil icon and UnBlock scribble are the sole hand-made signature. The logo and standard controls remain crisp.
- Touch targets, Dynamic Type/font scaling, screen-reader labels, reduced motion, and edge-to-edge behavior remain unchanged.
- Texture opacity is capped low enough that WCAG contrast is determined by the base surface and foreground colors, not the texture.

## Android Architecture

### Appearance state

- Add an `AppAppearance` enum with stable serialized values for `INK`, `PAPER`, and `GRAPHITE`.
- Persist it in `ProjectRepository` under a new appearance-specific DataStore key. Do not reuse `CURRENT_THEME_KEY`; that key stores the song's lyrical theme.
- Own the loaded value in `MainViewModel`, expose one setter, and persist changes immediately.
- Hoist the ViewModel above `RhymeAITheme` in `MainActivity` so the selected appearance controls the root composition.
- Disable Material You dynamic color for these authored styles; wallpaper colors would break the monochrome contract.

### Theme and components

- Expand `RhymeAITheme` to resolve an appearance palette and publish the effective appearance through a composition local.
- Replace direct `isSystemInDarkTheme()` decisions in safe-area, rhyme, syllable, editor, and help components with the effective app appearance so system bars and semantic palettes match the selected style.
- Keep Material 3 components. Express the redesign through `ColorScheme`, shared shape/surface tokens, and focused modifiers rather than custom button or switch implementations.
- Add an appearance-aware static writing-surface modifier for the editor, sheets, and large panels. Paper rules/fibers are clipped behind content and cached where drawing is required.
- Update the welcome screen, editor chrome, assistant, projects/trash drawer, settings, templates, shared segmented control, suggestion cards, and rewrite chips through shared tokens first; add screen-specific styling only where a shared primitive cannot express the result.

### Settings

- Add an Appearance section at the top of General settings.
- Use a three-option native/established segmented selector with a compact live preview swatch for each style.
- Apply the selection immediately; it does not depend on the existing Save Settings button, which remains scoped to provider/model credentials.

## iOS Architecture

### Appearance state

- Add an `AppAppearanceStyle: String, CaseIterable` with `ink`, `paper`, and `graphite` values.
- Store it with `@AppStorage` at the app root and inject it through a custom SwiftUI environment value.
- Apply `.preferredColorScheme(.light)` to Ink and Paper and `.preferredColorScheme(.dark)` to Graphite so UIKit-backed lyric editing and system chrome resolve consistently.
- Invalid legacy values resolve to Ink without crashing or resetting unrelated settings.

### Theme and components

- Add appearance-aware semantic palette and surface helpers alongside `RhymeAITokens`.
- Make the existing `liquidGlassSurface` seam appearance-aware: Ink uses crisp paper surfaces and thin neutral borders, Paper uses opaque warm surfaces with subtle static texture, and Graphite uses opaque charcoal surfaces with restrained neutral depth. The redesign does not layer glass over paper.
- Pass resolved foreground, caret, placeholder, and selection colors into the UIKit lyric editor explicitly.
- Update the welcome screen, editor, assistant panel, project drawer, settings, segmented controls, suggestion/rewrite surfaces, and sheets through the shared palette/surface seam.
- Keep native Liquid Glass available only where the selected style's contract permits it; the three authored styles should not reintroduce colored glass accents.

### Settings

- Add an Appearance section near the top of Settings with a three-option picker and compact preview cards.
- Selection writes through `@AppStorage` immediately and updates the presented sheet and underlying editor in the same transaction.

## Data Flow

1. App launch reads the persisted appearance value.
2. Missing or invalid value resolves to Ink Editorial.
3. The root theme/environment publishes the resolved palette and surface style.
4. Screens consume semantic tokens rather than checking the device theme directly.
5. A Settings selection updates root state immediately and persists it.
6. UIKit/Android system bars and lyric-editor bridges receive the same effective light/dark appearance.

Appearance changes never modify song data, current-project state, cloud backup data, or the song-level lyrical `theme` field.

## Error and Edge Handling

- Unknown stored values fall back to Ink Editorial.
- Failed preference writes leave the current in-memory appearance visible for the session and use the existing app error-reporting pattern where available; no destructive retry or preference reset occurs.
- Reduced transparency and increased contrast settings remove or further reduce decorative texture while preserving the base palette.
- Semantic analysis colors choose their existing light or dark contrast variants from the effective appearance, not the operating-system setting.
- Splash and system-bar colors match the selected family as closely as platform startup constraints allow. The launcher icon remains unchanged.

## Testing

- Android unit tests cover enum serialization, unknown-value fallback, repository persistence, and immediate ViewModel updates.
- iOS unit tests cover raw-value fallback and appearance-to-color-scheme resolution.
- Existing rhyme/syllable tests remain green and verify that effective appearance selects the correct semantic contrast palette.
- Android and iOS builds must pass with no new warnings in changed files.
- Manual QA switches through Ink, Paper, and Graphite from Settings, relaunches to confirm persistence, edits lyrics with the keyboard visible, opens assistant/projects/settings, and verifies system-bar and caret contrast.
- Capture screenshots of the editor and Settings on Android and iOS for all three styles. Verify that texture is not visible over glyphs and that no indigo/purple chrome remains outside semantic analysis/status uses.

## Performance Constraints

- No per-frame random grain generation.
- No blur outside platform chrome that explicitly retains it.
- No texture bitmap larger than the rendered surface; prefer procedural gradients or cached draw layers.
- Appearance changes may recompose/re-render the visible hierarchy once, but typing must not invalidate texture generation or unrelated panels.

## Rollout

- Implement shared appearance state and semantic tokens first.
- Convert shared surfaces and controls next.
- Convert screen-specific chrome last.
- Verify each platform independently, then compare screenshots side by side for parity.
- Preserve all unrelated accessibility, local-model, and finetune work already present in the shared worktree.
