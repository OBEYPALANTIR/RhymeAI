# Android Phi Rhythm and Writer's Marks Pass

Date: 2026-07-11
Status: Approved direction, awaiting written-spec review
Platform: Android

## Goal

Correct the Android app's uneven proportions and add restrained character while preserving the Ink, Paper, and Graphite appearance system the user already likes. Golden-ratio relationships guide the visual rhythm; they do not override accessibility, text fit, or native Android behavior.

## Proportion System

The focused surfaces use a Fibonacci-derived rhythm of **8, 13, 21, 34, and 55**:

- 8dp: tight icon, label, and inline gaps.
- 13dp: related-content gaps and compact internal spacing.
- 21dp: standard screen inset and component separation.
- 34dp: major section separation and resting bottom inset.
- 55dp: primary action and text-field visual height.

Android's 48dp minimum interactive target remains an accessibility exception; no control becomes harder to touch to satisfy the ratio. Existing 4dp and 5dp optical corrections remain available for strokes and alignment but do not define layout rhythm.

The focused type relationships are:

- 13sp metadata and supporting labels.
- 17sp lyric body with a 27sp line height.
- 21sp interface titles.
- 34sp editable song title with a 42sp line height.

Existing system scaling remains enabled. Long text, larger font scales, and narrow screens take precedence over fixed ratios.

## Editor Composition

### Top chrome

- Keep the navigation menu, sticky project title/save state, export, and settings in the top bar.
- Remove word and syllable counts from the top bar. They currently compete with the title and two actions in one short band.
- Preserve 48dp icon touch targets and the existing opaque monochrome surface.

### Writing column

- Use a 21dp horizontal inset and 21dp initial top inset.
- Render the editable song title at 34sp/42sp.
- Add one 13sp metadata line beneath it: `0 words · 0 syllables`. This line shares the writing-column alignment and updates through the existing delayed lyric analysis.
- Use an 8dp title-to-metadata gap and a 21dp metadata-to-lyrics gap.
- Render lyrics at 17sp/27sp. Existing rhyme, syllable, rewrite, caret, scroll, and keyboard behavior remains unchanged.
- Keep the editor open and uncarded; the empty writing surface is intentional negative space.

### Bottom actions

- Preserve the right-side placement and the existing order: UnBlock, then microphone.
- Set the resting action height and microphone diameter to 55dp.
- Set the UnBlock resting width to 144dp, the nearest whole dp to `55 × φ²`, while retaining content-fit expansion at larger accessibility font sizes.
- Keep an 8dp gap between actions, a 21dp right inset, and a 34dp resting bottom inset.
- Recording expansion continues to use the existing spring choreography and must remain within the safe screen width.

## Writer's Marks

1. **Title underline:** Focusing the song title draws a short deterministic underline beneath the title area. It settles while focused and withdraws when focus leaves.
2. **Saved flourish:** A small authored check appears beside the sticky title when autosave reaches `SAVED`, holds briefly, and fades. It supplements but does not replace the accessible saved status.
3. **Action press character:** UnBlock and microphone use a subtle press-and-settle scale response without translation or layout movement.

All marks reuse the UnBlock scribble language, inherit the active appearance foreground, and remain decorative in accessibility semantics. No doodles, labels, corner folds, extra color, sound, or haptics are added.

Title motion completes within 260ms, press feedback within 160ms, and the saved flourish remains visible for no more than 900ms. When animations are disabled, the focused underline is static, native press feedback remains, and the transient saved flourish is omitted.

## Settings Composition

- Use a 21dp horizontal inset and a 21sp Settings title.
- Use 34dp between major sections, 8dp between a section label and its first control, 13dp between a control and supporting text, and 21dp between related fields.
- Keep General and Editor as the only primary settings tabs.
- Keep the live Appearance segmented selector but remove the redundant three-card preview strip; the entire settings surface already previews the selected appearance immediately.
- Use a 42dp visible track for segmented controls inside a 48dp minimum touch target. Keep native Material text fields and dropdowns at 56dp, the platform-rounded equivalent of the 55dp tier. Set the pinned Save Settings action to 55dp.
- Preserve native field, menu, switch, and button behavior. Do not replace them with decorative custom controls.
- Retain the existing restrained radius tokens: 12dp fields, 22dp sheets, and 28dp/full-pill geometry only for segmented controls and actions.

## Architecture

- Keep the change within Android Compose UI and existing theme tokens.
- Add focused editor typography and rhythm tokens rather than changing every legacy spacing token and accidentally inflating unrelated screens.
- Drive metadata from the existing `LyricStats`, title focus from local focus state, save flourish from `SaveStatus`, and press motion from Compose interaction state.
- Do not add ViewModel state, persistence, business logic, dependencies, or settings.
- Keep the title underline and saved check beside their consumers because their geometry and timing serve different states.

## Accessibility and Adaptation

- Decorative paths are excluded from semantics.
- Existing labels, roles, save announcements, keyboard behavior, focus behavior, and edge-to-edge behavior remain unchanged.
- Touch targets stay at least 48dp even where the visible geometry is smaller.
- Large font scales may grow the top bar title and UnBlock width rather than clip their labels.
- Reduced-motion behavior follows `LocalAnimationsEnabled`.
- Foreground contrast continues to come from the authored Ink, Paper, and Graphite palettes.

## Testing and Manual QA

- Add unit coverage for the 144dp UnBlock resting-width calculation and accessibility content-fit behavior.
- Keep the existing instrumented regression proving the action group remains on the right edge.
- Add an instrumented layout assertion proving word/syllable metadata is below the title and no longer occupies the top-bar action cluster.
- Build the debug APK and run targeted unit, lint, and instrumented tests.
- Manually focus the title, edit lyrics until autosave completes, press UnBlock, press the microphone, and switch Settings sections in the emulator.
- Capture editor and Settings screenshots in Ink, Paper, and Graphite at the reference phone size, plus one large-font pass.
- Confirm the top bar no longer feels crowded, the writing hierarchy reads 34/17/13, bottom actions remain right aligned, Settings has a clear 34/21/13/8 rhythm, and the character marks remain subordinate to writing.

## Non-goals

- No navigation, assistant, project drawer, AI, recording, persistence, or iOS behavior changes.
- No global rewrite of every app token or component.
- No additional color, font family, texture intensity, card system, illustration, sound, or haptic layer.
