---
version: "alpha"
name: "Writers Block"
description: "A dark, lyric-first mobile design system for a songwriting assistant with Material You adaptation on Android and Liquid Glass depth on iOS."
colors:
  primary: "#4F46E5"
  on-primary: "#FFFFFF"
  primary-container: "#6366F1"
  on-primary-container: "#FFFFFF"
  primary-soft: "#818CF8"
  secondary: "#C084FC"
  on-secondary: "#FFFFFF"
  tertiary: "#6EE7B7"
  on-tertiary: "#003824"
  tertiary-container: "#005235"
  on-tertiary-container: "#90F7C4"
  background: "#0A0A0A"
  on-background: "#FFFFFF"
  surface: "#0A0A0A"
  surface-container-low: "#111111"
  surface-container: "#1A1A1A"
  surface-container-high: "#222222"
  surface-container-highest: "#333333"
  on-surface: "#FFFFFF"
  on-surface-muted: "#B3B3B3"
  on-surface-subtle: "#666666"
  outline: "#333333"
  outline-bright: "#FFFFFF"
  inverse-surface: "#FFFFFF"
  inverse-on-surface: "#0A0A0A"
  error: "#FFB4AB"
  on-error: "#690005"
  success: "#6EE7B7"
  warning: "#FFA000"
  app-icon-coral: "#FF7A73"
  app-icon-burgundy: "#4A000B"
  app-icon-light: "#FFFFFF"
  app-icon-ink: "#050505"
  android-dynamic-background: "#2B0008"
  android-dynamic-primary: "#FF8982"
  android-dynamic-on-primary: "#4B000B"
  ios-glass-surface: "#252837"
  ios-glass-border: "#50577A"
  ios-glass-icon-fill: "#303556"
  syllable-1: "#6EE7B7"
  syllable-2: "#93C5FD"
  syllable-3: "#D8B4FE"
  syllable-4-plus: "#FDA4AF"
  rhyme-01: "#FCA5A5"
  rhyme-02: "#FCD34D"
  rhyme-03: "#86EFAC"
  rhyme-04: "#7DD3FC"
  rhyme-05: "#C4B5FD"
  rhyme-06: "#F9A8D4"
  rhyme-07: "#FDBA74"
  rhyme-08: "#67E8F9"
  rhyme-09: "#A7F3D0"
  rhyme-10: "#E9D5FF"
  rhyme-11: "#FEF08A"
  rhyme-12: "#BEF264"
  light-background: "#FBFBFE"
  light-surface: "#FBFBFE"
  light-surface-container: "#F0F0F5"
  light-on-surface: "#1B1B1F"
  light-on-surface-muted: "#46464F"
  light-outline: "#767680"
  light-outline-variant: "#C6C5D0"
typography:
  display-lg:
    fontFamily: "System Serif"
    fontSize: 44px
    fontWeight: "700"
    lineHeight: 52px
    letterSpacing: 0em
  display-md:
    fontFamily: "System Serif"
    fontSize: 40px
    fontWeight: "700"
    lineHeight: 48px
    letterSpacing: 0em
  headline-lg:
    fontFamily: "System Serif"
    fontSize: 32px
    fontWeight: "700"
    lineHeight: 40px
    letterSpacing: 0em
  headline-md:
    fontFamily: "System Serif"
    fontSize: 28px
    fontWeight: "700"
    lineHeight: 36px
    letterSpacing: 0em
  title-lg:
    fontFamily: "System Sans"
    fontSize: 20px
    fontWeight: "500"
    lineHeight: 28px
    letterSpacing: 0em
  title-md:
    fontFamily: "System Sans"
    fontSize: 16px
    fontWeight: "600"
    lineHeight: 24px
    letterSpacing: 0em
  body-lg:
    fontFamily: "System Sans"
    fontSize: 16px
    fontWeight: "400"
    lineHeight: 24px
    letterSpacing: 0em
  lyric-body:
    fontFamily: "System Sans"
    fontSize: 16px
    fontWeight: "400"
    lineHeight: 28px
    letterSpacing: 0em
  body-md:
    fontFamily: "System Sans"
    fontSize: 14px
    fontWeight: "400"
    lineHeight: 20px
    letterSpacing: 0em
  body-sm:
    fontFamily: "System Sans"
    fontSize: 12px
    fontWeight: "400"
    lineHeight: 16px
    letterSpacing: 0em
  label-md:
    fontFamily: "System Sans"
    fontSize: 12px
    fontWeight: "500"
    lineHeight: 16px
    letterSpacing: 0em
  caption-mono:
    fontFamily: "System Monospace"
    fontSize: 12px
    fontWeight: "400"
    lineHeight: 16px
    letterSpacing: 0em
rounded:
  none: 0px
  xs: 6px
  sm: 8px
  md: 10px
  lg: 12px
  xl: 14px
  xxl: 16px
  xxxl: 18px
  sheet: 22px
  pill: 28px
  app-icon: 22px
  app-icon-shell: 30px
  full: 9999px
spacing:
  unit: 4px
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 20px
  xxl: 24px
  xxxl: 32px
  jumbo: 48px
  screen-horizontal: 24px
  editor-horizontal: 20px
  drawer-horizontal: 16px
  assistant-panel: 20px
  card-gap: 12px
  section-gap: 16px
  sheet-handle-area: 64px
  editor-bottom-rest: 300px
proportion:
  phi: 1.618
  inverse-phi: 0.618
  rhythm: "8px, 12/13px, 20/21px, 32/34px, 52/55px"
  editor-assistant-drawer: "Size major editor, assistant, and drawer relationships with inverse-phi proportions before rounding to platform-friendly pixels."
  exceptions: "Minimum touch targets and keyboard/safe-area offsets override phi: 48px web, 48dp Android, 44pt iOS."
opacity:
  disabled: 0.40
  placeholder: 0.20
  subtle-text: 0.50
  muted-text: 0.60
  outline-variant: 0.10
  glass-border: 0.12
  glass-tint-low: 0.05
  glass-tint-medium: 0.08
  glass-tint-strong: 0.35
  scrim: 0.42
  rhyme-text: 0.90
elevation:
  flat: 0px
  android-icon-tonal: 4px
  android-icon-shadow: 6px
  drawer-tonal: 8px
  ios-brand-glow-radius: 22px
  ios-brand-glow-y: 10px
  ios-drawer-shadow-radius: 26px
  ios-drawer-shadow-x: 10px
  fab-shadow-radius: 12px
  fab-shadow-y: 4px
shadows:
  ios-brand-glow: "0px 10px 22px rgba(79, 70, 229, 0.32)"
  ios-drawer: "10px 0px 26px rgba(0, 0, 0, 0.35)"
  ios-primary-action: "0px 4px 12px rgba(79, 70, 229, 0.26)"
  android-surface-resting: "0px 6px 12px rgba(0, 0, 0, 0.24)"
motion:
  fast: "160ms"
  standard: "260ms"
  provider-expand: "260ms"
  assistant-present: "260ms"
  assistant-settle: "420ms"
  rewrite-chip: "260ms"
  easing-standard: "ease-in-out"
  spring-standard: "response 260ms, damping 0.88"
  spring-settle: "response 420ms, damping 0.80"
  spring-expressive: "response 400ms, damping 0.76"
  purpose:
    phi-ladder: "Fast, standard/present, and settle tiers use a golden-ratio ladder: 160ms ×φ ≈260ms ×φ ≈420ms."
    feedback-dismiss: "160ms for immediate feedback, press states, and dismissals."
    state-dialog: "260ms for ordinary state changes, settings growth, dialogs, assistant panels, sheets, drawers, and rewrite chips."
    drag-settle: "420ms for drag release and spring settle with damping 0.80; expressive mic choreography preserves damping 0.76."
    avoid: "Avoid decorative hover motion and staggered choreography that does not clarify state or origin."
effects:
  ios-glass-material: "ultra-thin translucent material"
  ios-glass-border-width: 1px
  android-outline-width: 1px
  underline-stroke: 3px
  unblock-scribble-stroke: 1.6px
components:
  app-screen:
    backgroundColor: "{colors.background}"
    textColor: "{colors.on-background}"
    typography: "{typography.body-lg}"
  welcome-title:
    backgroundColor: "transparent"
    textColor: "{colors.primary}"
    typography: "{typography.display-lg}"
  welcome-subtitle:
    backgroundColor: "transparent"
    textColor: "{colors.on-surface-muted}"
    typography: "{typography.body-lg}"
  android-welcome-card:
    backgroundColor: "{colors.surface-container-low}"
    textColor: "{colors.on-surface}"
    typography: "{typography.title-md}"
    rounded: "{rounded.xxl}"
    padding: 20px 16px
  ios-glass-card:
    backgroundColor: "rgba(255, 255, 255, 0.06)"
    textColor: "{colors.on-surface}"
    typography: "{typography.title-md}"
    rounded: "{rounded.xxl}"
    padding: 16px
  icon-tile:
    backgroundColor: "rgba(79, 70, 229, 0.15)"
    textColor: "{colors.primary-soft}"
    rounded: "{rounded.md}"
    size: 44px
  top-bar:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface-muted}"
    typography: "{typography.label-md}"
    height: 64px
    titleRule: "Editor top bar persistently shows the current song name, or \"Untitled Song\" when empty, with save status as a compact adjacent indicator; the large in-scroll title field remains the editor."
  editor-title-field:
    backgroundColor: "transparent"
    textColor: "{colors.on-background}"
    typography: "{typography.headline-lg}"
  lyric-editor:
    backgroundColor: "transparent"
    textColor: "{colors.on-background}"
    typography: "{typography.lyric-body}"
  primary-action-fab:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.title-md}"
    rounded: "{rounded.pill}"
    height: 56px
    padding: 14px 20px
  assistant-sheet:
    backgroundColor: "{colors.surface-container-low}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.none}"
  assistant-primary-button:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.title-md}"
    rounded: "{rounded.lg}"
    height: 48px
    padding: 14px
  drawer-panel:
    backgroundColor: "{colors.surface-container-low}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.none}"
    width: 360px
  drawer-row:
    backgroundColor: "{colors.surface-container}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xxl}"
    padding: 12px 14px
  drawer-row-active:
    backgroundColor: "rgba(79, 70, 229, 0.18)"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xxl}"
    padding: 12px 14px
  search-field:
    backgroundColor: "{colors.surface-container-low}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xxl}"
    height: 46px
    padding: 0px 12px
  settings-card:
    backgroundColor: "rgba(255, 255, 255, 0.06)"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sheet}"
    padding: 16px
  compact-info-pill:
    backgroundColor: "{colors.surface-container-high}"
    textColor: "{colors.on-surface-muted}"
    typography: "{typography.caption-mono}"
    rounded: "{rounded.xs}"
    padding: 4px 8px
  primary-container-surface:
    backgroundColor: "{colors.primary-container}"
    textColor: "{colors.app-icon-ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xxl}"
    padding: 16px
  primary-container-label-on-dark:
    backgroundColor: "{colors.background}"
    textColor: "{colors.on-primary-container}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px 8px
  secondary-action:
    backgroundColor: "{colors.secondary}"
    textColor: "{colors.inverse-on-surface}"
    typography: "{typography.title-md}"
    rounded: "{rounded.lg}"
    height: 48px
    padding: 14px
  secondary-label-on-dark:
    backgroundColor: "{colors.background}"
    textColor: "{colors.on-secondary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px 8px
  tertiary-status:
    backgroundColor: "{colors.tertiary}"
    textColor: "{colors.on-tertiary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px 8px
  tertiary-container-status:
    backgroundColor: "{colors.tertiary-container}"
    textColor: "{colors.on-tertiary-container}"
    typography: "{typography.label-md}"
    rounded: "{rounded.lg}"
    padding: 12px
  high-surface-panel:
    backgroundColor: "{colors.surface-container-highest}"
    textColor: "{colors.on-surface-muted}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.xxl}"
    padding: 16px
  subtle-text-on-light:
    backgroundColor: "{colors.inverse-surface}"
    textColor: "{colors.on-surface-subtle}"
    typography: "{typography.body-sm}"
  divider:
    backgroundColor: "{colors.outline}"
    textColor: "{colors.on-surface-muted}"
    height: 1px
  glass-edge:
    backgroundColor: "{colors.outline-bright}"
    textColor: "{colors.inverse-on-surface}"
    height: 1px
  inverse-toast:
    backgroundColor: "{colors.inverse-surface}"
    textColor: "{colors.inverse-on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xxl}"
    padding: 12px 16px
  error-banner:
    backgroundColor: "{colors.error}"
    textColor: "{colors.on-error}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: 12px
  success-pill:
    backgroundColor: "{colors.success}"
    textColor: "{colors.on-tertiary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px 8px
  warning-pill:
    backgroundColor: "{colors.warning}"
    textColor: "{colors.inverse-on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px 8px
  app-icon-android:
    backgroundColor: "{colors.app-icon-coral}"
    textColor: "{colors.app-icon-burgundy}"
    rounded: "{rounded.app-icon}"
    size: 80px
  app-icon-ios:
    backgroundColor: "{colors.app-icon-light}"
    textColor: "{colors.app-icon-ink}"
    rounded: "{rounded.app-icon}"
    size: 82px
  android-dynamic-screen:
    backgroundColor: "{colors.android-dynamic-background}"
    textColor: "{colors.android-dynamic-primary}"
    typography: "{typography.body-lg}"
  android-dynamic-fab:
    backgroundColor: "{colors.android-dynamic-primary}"
    textColor: "{colors.android-dynamic-on-primary}"
    typography: "{typography.title-md}"
    rounded: "{rounded.pill}"
    height: 56px
    padding: 14px 20px
  ios-glass-panel:
    backgroundColor: "{colors.ios-glass-surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xxl}"
    padding: 16px
  ios-glass-panel-edge:
    backgroundColor: "{colors.ios-glass-border}"
    textColor: "{colors.on-surface}"
    height: 1px
  ios-glass-icon-tile:
    backgroundColor: "{colors.ios-glass-icon-fill}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.xxl}"
    size: 44px
  syllable-one-underline:
    backgroundColor: "{colors.syllable-1}"
    textColor: "{colors.inverse-on-surface}"
    height: 3px
  syllable-two-underline:
    backgroundColor: "{colors.syllable-2}"
    textColor: "{colors.inverse-on-surface}"
    height: 3px
  syllable-three-underline:
    backgroundColor: "{colors.syllable-3}"
    textColor: "{colors.inverse-on-surface}"
    height: 3px
  syllable-four-plus-underline:
    backgroundColor: "{colors.syllable-4-plus}"
    textColor: "{colors.inverse-on-surface}"
    height: 3px
  rhyme-swatch-01:
    backgroundColor: "{colors.rhyme-01}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-02:
    backgroundColor: "{colors.rhyme-02}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-03:
    backgroundColor: "{colors.rhyme-03}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-04:
    backgroundColor: "{colors.rhyme-04}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-05:
    backgroundColor: "{colors.rhyme-05}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-06:
    backgroundColor: "{colors.rhyme-06}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-07:
    backgroundColor: "{colors.rhyme-07}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-08:
    backgroundColor: "{colors.rhyme-08}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-09:
    backgroundColor: "{colors.rhyme-09}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-10:
    backgroundColor: "{colors.rhyme-10}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-11:
    backgroundColor: "{colors.rhyme-11}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  rhyme-swatch-12:
    backgroundColor: "{colors.rhyme-12}"
    textColor: "{colors.inverse-on-surface}"
    size: 18px
    rounded: "{rounded.full}"
  light-screen:
    backgroundColor: "{colors.light-background}"
    textColor: "{colors.light-on-surface}"
    typography: "{typography.body-lg}"
  light-card:
    backgroundColor: "{colors.light-surface}"
    textColor: "{colors.light-on-surface-muted}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xxl}"
    padding: 16px
  light-container:
    backgroundColor: "{colors.light-surface-container}"
    textColor: "{colors.light-on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xxl}"
    padding: 16px
  light-divider:
    backgroundColor: "{colors.light-outline}"
    textColor: "{colors.app-icon-ink}"
    height: 1px
  light-subtle-divider:
    backgroundColor: "{colors.light-outline-variant}"
    textColor: "{colors.light-on-surface}"
    height: 1px
---

## Overview

Writers Block is a dark, focused songwriting workspace. The interface should feel like a quiet writing room with a powerful assistant close at hand: black canvas, soft luminous accents, large serif song titles, restrained controls, and color only where it helps the writer understand rhythm, rhyme, or action.

The product is shared across Android and iOS, but each platform speaks its native language. Android uses Material 3 structure and can harmonize with Material You dynamic colors. iOS uses a glass-forward visual model with translucent panels, soft borders, and native-feeling depth. The shared identity is not a rigid color match; it is a shared hierarchy, rhythm, and lyric-first mood.

## Colors

The canonical palette is near-black with indigo, purple, and emerald accents. Black is the dominant working surface. Indigo is the main action color, purple supports brand expression, emerald marks successful or local states, and a coral app-icon family provides warmth when dynamic color or brand imagery is present.

Android enables Material You dynamic color by default in `Theme.kt`, so the authored indigo, purple, and emerald palette is the non-dynamic baseline; on Android 12+ it can be replaced by the user's wallpaper palette. When that happens, keep the same tonal relationships: a very dark canvas, a high-contrast primary action, subdued card outlines, and muted secondary text.

iOS should bias toward black, indigo, purple, and translucent blue-gray glass. Glass surfaces should be visible through border, tint, blur, and shadow rather than through solid fill. Avoid opaque cards on iOS unless the content is modal and needs firm legibility.

Rhyme and syllable colors are functional tokens, not decoration. Syllable underlines use four stable colors by syllable count. Rhyme colors cycle through a broader palette so matching colors imply matching rhyme families. When Rhyme Highlight is on, syllable cues render as underlines beneath each word; when Rhyme Highlight is off, Syllable Coloring instead tints each whole word (semibold) by its syllable count, mirroring rhyme highlight's word coloring so the foreground color is never double-claimed.

## Typography

The typographic voice pairs expressive serif display text with plain system sans text. Song titles, welcome headlines, and large editor placeholders use bold serif type to make writing feel personal and editorial. Controls, labels, settings, metadata, and assistant content use system sans for scan speed and platform familiarity.

Lyric text needs more breathing room than standard body copy. Use a 16px size with a 28px line height for writing and highlighted lyric overlays. This keeps colored rhyme and syllable cues readable without making the editor feel crowded.

Secondary and support text — dialog captions, sheet metadata, and inline labels — sits at a 13px caption size. This is the upper half of the 12/13px caption tier in the φ-rounded rhythm above, kept one step below the 14px control text so supporting copy reads as quieter without dropping to the 12px fine-print rung.

Letter spacing stays neutral. Do not tighten display text; the heavy serif forms already carry enough character.

## Layout

The welcome screen is centered and calm. It should lead with the app icon, then the Writers Block wordmark, then a short explanation, then three large actions. On compact screens, vertical spacing can compress, but the page should still feel centered rather than packed.

The editor is the primary workspace. It uses a fixed top toolbar, a full-screen dark writing area, 20px to 24px side padding, a large title field, and a long bottom rest area so the last lyric line can settle comfortably above controls and keyboards.

Assistant controls live in a bottom sheet on phones and a persistent side panel on large screens. The sheet should feel like it rises from the working surface, not like a separate page. The drawer for projects enters from the left, covers the full height, and contains search first, new song second, then recent songs.

Spacing should follow a 4px base with 8px, 12px, 16px, 20px, 24px, 32px, and 48px as the normal visible rhythm. Avoid odd one-off gaps unless they solve a specific safe-area or keyboard problem.

The spacing table describes relative rhythm, not exact per-platform pixels; shipped values live in Android `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/DesignTokens.kt` and iOS `RhymeAITokens` in `Writers Block/Writers Block/Views/LiquidGlassSupport.swift`, with dp/pt scales tuned independently.

Major structure should use φ=1.618 as a practical proportion rule, especially the relationship between the lyric editor and assistant or drawer surfaces. Size supporting panels with inverse-φ relationships to the editor, then round to the shared visible rhythm: 8px, 12/13px, 20/21px, 32/34px, and 52/55px. This ratio is a hierarchy tool, not a rigid grid; minimum touch targets and system geometry override it: 48px on web, 48dp on Android, 44pt on iOS, plus any keyboard or safe-area offsets needed to keep writing usable.

## Elevation & Depth

Depth is subtle. Android surfaces mostly use Material tonal elevation, 1px outlines, and dark containers. iOS surfaces use material blur, translucent tint, a 1px light border, and soft shadows.

On iOS 26+, native `.glassEffect` renders Liquid Glass with its own edge; the explicit 1px light border applies to the pre-iOS-26 `.ultraThinMaterial` fallback in `LiquidGlassSurfaceModifier`, while soft shadows remain part of the broader iOS surface treatment where callers apply them.

The app icon can glow. Primary action buttons can cast a small accent shadow. Drawers can cast a directional shadow to reinforce lateral motion. Standard editor content should remain flat so the lyric text stays dominant.

Scrims should be dark and functional. Use them to explain modality, not to create a separate dramatic layer.

## Motion

Motion must explain cause, state, or spatial origin. Use 180ms for immediate feedback and dismissals, 260ms for ordinary state changes and dialogs, 340ms when assistant panels, sheets, or drawers present from their physical origin, and 420ms for drag release settle. Avoid decorative hover effects and staggered choreography unless they make state or motion origin clearer.

## Shapes

The shape language is soft but not bubbly. Cards and rows use 16px corners. Settings and glass grouped surfaces can use 18px to 22px. Floating actions use a 28px pill. App icon artwork keeps a 22px inner corner with a 30px glass shell on iOS.

The rounded table describes shape intent, not exact per-platform pixels; shipped radii live in Android `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/DesignTokens.kt` and iOS `RhymeAITokens` in `Writers Block/Writers Block/Views/LiquidGlassSupport.swift`, with platform-specific dp/pt tuning.

Drawers are squared to the screen edge. Bottom sheets are full-width and full-height when active, with the drag handle carrying the affordance instead of a rounded container edge.

## Components

Component dimensions and radii below express relative rhythm and intent, not exact per-platform pixels. Shipped per-platform values are authoritative in Android `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/DesignTokens.kt` and iOS `RhymeAITokens` in `Writers Block/Writers Block/Views/LiquidGlassSupport.swift`, and their dp/pt scales intentionally differ where native feel requires it.

Welcome cards are large repeated actions. Android cards are outlined Material surfaces. iOS cards are translucent glass surfaces with tinted icon tiles. Both should share the same information order: icon, title, supporting text, and an optional trailing affordance.

The UnBlock action uses a pencil icon and a scribble underline under the word "UnBlock." It should read as a creative writing action, not as a magic or automation action. The scribble is part of the brand vocabulary and should stay low, thin, and hand-marked.

Assistant panels are dense operational surfaces. Use segmented controls for density, sliders for complexity, switches for feature toggles, help buttons for explanations, and a single strong primary action for suggestions. Keep each control aligned with its label so the panel feels practical rather than decorative.

Project drawers should be utilitarian and stable. Search is the first control. Create New Song is the second control. Recent Songs is the main content area. Import belongs at the bottom. The drawer slides in from the left and dismisses back to the left.

Settings use grouped glass or outlined containers with smooth content growth when provider-specific sections change. Provider switching should feel like a panel expanding in place, not like the whole dialog snaps to a new size after content appears.

## Do's and Don'ts

Do keep the lyric editor visually quiet.

Do preserve platform-native behavior: Material 3 and dynamic color on Android, Liquid Glass and native sheets on iOS.

Do use serif type for song identity and sans type for controls.

Do keep rhyme and syllable colors semantically stable.

Do let actions and panels animate from their physical origin: bottom sheets rise, drawers slide from the left, selected chips emerge from the bottom.

Don't turn the app into a bright productivity dashboard.

Don't use decorative gradients or extra glow in the editor.

Don't make Android and iOS visually identical at the expense of platform conventions.

Don't use magic-wand imagery for UnBlock or context controls.

Don't let panel transitions snap, jump, or recenter after content has already appeared.
