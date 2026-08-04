# RhymeAI Focused Visual and Accessibility Polish Design

Date: 2026-07-12
Status: Approved design, pending written-spec review
Platforms: Android and iOS/iPadOS

## Problem

The Ink, Paper, and Graphite identity is established, but the current app still has four visible maturity gaps from the product audit:

- compact editor headers surrender song-title space too aggressively;
- low-emphasis text can become too faint in Graphite;
- welcome-card copy wraps awkwardly at narrow widths and larger text sizes;
- rhyme and syllable analysis depends too heavily on color.

These issues do not require new navigation or a new visual language. They require a focused pass through the existing tokens, layouts, and analysis renderers.

## Goals

- Preserve more readable song-title context in compact editor chrome.
- Ensure secondary and placeholder text meets the intended Graphite contrast contract.
- Make welcome cards stable across phone, tablet, compact height, and accessibility text sizes.
- Add a persistent analysis presentation choice between the existing semantic colors and a monochrome `Ink Marks` treatment.
- Keep Android and iOS behavior aligned while using native rendering and accessibility APIs.
- Preserve editor responsiveness and all current rhyme/syllable calculations.

## Non-goals

- Revision checkpoints beyond the completed undo/redo work.
- Active-provider badges or expanded custom-model management.
- Timed-lyrics authoring, onboarding, song tags/collections, or section reordering.
- Resizable iPad columns, multi-window support, or distraction-free mode.
- Replacing the three appearance styles or changing existing analysis defaults.

## Product Decisions

### Analysis presentation

Settings exposes an `Analysis Style` selector with two values:

1. `Color` preserves the current semantic rhyme-family and syllable-count colors and remains the default for existing users.
2. `Ink Marks` uses only the active appearance's primary and secondary ink colors. Rhyme families use deterministic underline patterns, while syllable counts use progressive text weights.

The selector includes a compact live preview and legend. The choice persists independently from the Ink/Paper/Graphite appearance choice and from song data.

### Ink Marks encoding

- A rhyme family maps deterministically to one of four patterns: solid, dashed, dotted, or dash-dot.
- The mapping is stable across launches and platforms for the same rhyme-family key.
- Syllable count maps to text weight: one syllable regular, two medium, three semibold, and four or more bold.
- When rhyme and syllable analysis are both enabled, the underline pattern and text weight coexist.
- Non-analysis text always uses the normal primary ink and body weight.
- Accessibility descriptions and the Settings preview explain both encodings; the feature does not require users to infer the legend from color or pattern alone.

## Compact Editor Chrome

### iOS

- Give the title/save cluster higher layout priority than counters.
- Use `ViewThatFits(in: .horizontal)`: show full word/syllable labels when space permits and a compact `12w · 18s` form when it does not.
- Keep menu, Share, Settings, and save status reachable at all supported widths.
- Preserve the existing two-row accessibility-size top bar.
- Use the appearance's authored secondary ink instead of system `.secondary` for top-bar text and icons.

### Android

- Make the top-bar title consume the remaining width after fixed navigation/actions, with ellipsis only after that space is exhausted.
- Keep save status beside the title without allowing it to push the title cluster out of bounds.
- Keep Menu, Share, and Settings at Material minimum touch size.
- Use the authored `onSurfaceVariant` role and verify it against Graphite surfaces.

The full editable song title remains in the writing surface on both platforms; compact chrome provides context rather than replacing that field.

## Graphite Contrast

- Audit secondary labels, placeholders, helper copy, counters, and disabled-but-readable text on Welcome, Editor chrome, and Assistant.
- Route app-owned text through appearance-aware semantic roles rather than stacking system secondary colors with additional opacity.
- Normal text must meet 4.5:1 contrast and large text or interactive boundaries must meet 3:1.
- Disabled controls may be lower emphasis, but their labels and state must remain recognizable without relying on hue.
- Ink and Paper values must not regress while correcting Graphite.

## Welcome Cards

- The icon and trailing affordance retain fixed geometry; the text column receives the flexible width.
- Titles and subtitles wrap as complete blocks and grow vertically instead of clipping or forcing the chevron off-screen.
- iPad cards retain balanced equal widths in the horizontal arrangement; accessibility text sizes use the existing vertical arrangement.
- Android phone cards give the text column `weight(1)` and retain native minimum touch height.
- iOS uses explicit vertical fixed sizing and layout priority for card copy.
- Secondary welcome copy uses authored appearance tokens with verified Graphite contrast.

## State and Data Flow

### iOS

- Add `AnalysisPresentationStyle: String, CaseIterable` with stable `color` and `inkMarks` raw values.
- Store it with a dedicated `@AppStorage` key at the app root, resolve unknown values to `color`, and inject the resolved value and binding through SwiftUI environment values.
- Settings writes through the binding immediately.
- `RhymeHighlightedText` and `SyllableColoredText` consume the environment value and reuse the existing word-analysis cache.

### Android

- Add an `AnalysisPresentation` enum with stable serialized values and unknown-value fallback to `COLOR`.
- Persist it under a dedicated DataStore key in `ProjectRepository` and expose it through `MainViewModel` with an immediate setter.
- Publish the current value through a composition local at the app theme/root boundary.
- Settings updates in-memory state immediately and persists asynchronously using the existing repository pattern.
- Analysis components consume the composition local; they do not read preferences directly.

Analysis-style changes never modify lyrics, projects, rhyme settings, appearance choice, provider/model choice, or API keys.

## Rendering Architecture

### iOS

- Extend attributed-string analysis generation to choose either semantic colors or authored ink.
- Use `Text.LineStyle` patterns for rhyme-family underlines.
- Apply the syllable-derived font weight while constructing each word segment.
- Keep all analysis construction deterministic and cache-friendly; changing the presentation style invalidates only the visible attributed result.

### Android

- Reuse the existing `TextLayoutResult`/`drawBehind` underline path used for syllable marks.
- Generate rhyme underline spans containing stable word ranges and pattern identifiers.
- Draw solid, dashed, dotted, and dash-dot paths with appearance ink and density-aware stroke/gap values.
- Apply syllable-derived font weights in the corresponding annotated-string spans.
- Memoize generated spans and attributed strings by text, enabled analysis flags, presentation style, and effective appearance.

No raster textures, custom fonts, per-frame randomness, or decorative animation is introduced.

## Error and Edge Handling

- Missing or invalid stored analysis values resolve to `Color` without resetting unrelated settings.
- Empty lyrics produce no analysis spans.
- Unknown pronunciation results remain normal body text.
- More than four rhyme families reuse patterns deterministically; a family never changes pattern within the same text.
- Wrapped words draw each underline segment within its rendered line bounds.
- Reduced Motion does not change analysis meaning; the style switch adds no new animation.
- Dynamic Type/font scaling may increase card/header height but must not clip controls or text.

## Testing

### Unit and component tests

- Raw-value fallback and persistence for both platforms.
- Stable rhyme-family-to-pattern assignment across repeated runs.
- Syllable-count-to-weight mapping for counts one through four-plus.
- Color mode remains output-compatible with current analysis behavior.
- New presentation state does not modify song or appearance state.
- Compact counter formatting is covered as pure logic on both platforms.

### UI tests

- Long song titles preserve useful context on compact phones while Share and Settings remain reachable.
- Welcome cards render without clipped copy at standard and accessibility text sizes.
- Analysis Style changes immediately and remains selected after relaunch.
- Ink Marks renders with both rhyme and syllable analysis enabled.
- Graphite Welcome, Editor, and Assistant retain readable secondary text.

### Fresh visual evidence

The final current build must capture every changed page/state:

1. iPhone Welcome at standard text size.
2. iPhone Welcome at an accessibility text size.
3. iPhone compact Editor with a long title and Color analysis.
4. iPhone compact Editor with the same content in Ink Marks.
5. iPhone Graphite Assistant.
6. iPad Welcome horizontal cards.
7. iPad Editor top bar with a long title and Ink Marks.
8. Android Welcome at standard font scale.
9. Android Welcome at large font scale.
10. Android compact Editor with a long title and Color analysis.
11. Android compact Editor with the same content in Ink Marks.
12. Android Graphite Assistant.

Two independent read-only visual reviews must inspect all twelve fresh states. Any blocking contrast, wrapping, clipping, or design-system finding is fixed and recaptured before completion.

## Performance Constraints

- Typing must not trigger preference reads or rebuild appearance textures.
- Pattern drawing remains proportional to visible analyzed words and uses cached word analysis.
- No layout measurement loops or unbounded caches.
- Compact-header branching uses native layout negotiation rather than geometry polling.
- Welcome-card changes do not introduce nested scrolling or fixed heights that fight Dynamic Type.

## Acceptance Criteria

- Color remains the default and visually matches the current analysis presentation.
- Ink Marks communicates rhyme families and syllable counts without hue.
- Song titles receive measurably more compact-header width without hiding required actions.
- Welcome copy does not clip or collide in the enumerated phone/tablet and text-size states.
- Graphite secondary text and interactive boundaries meet the stated contrast thresholds.
- Android and iOS builds, focused tests, and changed-flow UI tests pass.
- All twelve fresh captures receive independent visual PASS verdicts with no blockers.
