---
version: "2026-08-04"
name: "Writers Block"
description: "A lyric-first, ink-and-paper mobile design system with three authored monochrome appearances."
default-appearance: "ink"
appearance:
  storage-values:
    ink: "Ink Editorial"
    paper: "Paper Notebook"
    graphite: "Graphite Night"
  palettes:
    ink:
      color-scheme: "light"
      background: "#FCFCF8"
      on-background: "#050505"
      surface: "#FCFCF8"
      surface-container-low: "#F7F7F2"
      surface-container: "#EFEFE9"
      surface-container-high: "#E5E5DE"
      surface-container-highest: "#DADAD2"
      on-surface: "#050505"
      on-surface-muted: "#4D4D48"
      on-surface-subtle: "#666660"
      outline: "#B5B5AD"
      outline-strong: "#5E5E58"
      action: "#050505"
      on-action: "#FCFCF8"
      caret: "#050505"
      placeholder: "#5E5E58"
      selection: "#DADAD2"
      scrim: "rgba(5, 5, 5, 0.42)"
    paper:
      color-scheme: "light"
      background: "#F3EEDF"
      on-background: "#302E2A"
      surface: "#F8F3E6"
      surface-container-low: "#EFE8D7"
      surface-container: "#E8E0CE"
      surface-container-high: "#DDD4BF"
      surface-container-highest: "#D2C8B0"
      on-surface: "#302E2A"
      on-surface-muted: "#5D574E"
      on-surface-subtle: "#6E675C"
      outline: "#B7AC94"
      outline-strong: "#696257"
      action: "#302E2A"
      on-action: "#FFF9EB"
      caret: "#302E2A"
      placeholder: "#5D574E"
      selection: "#D8CDB4"
      scrim: "rgba(48, 46, 42, 0.42)"
    graphite:
      color-scheme: "dark"
      background: "#171716"
      on-background: "#F6F2E8"
      surface: "#1C1C1B"
      surface-container-low: "#20201E"
      surface-container: "#232321"
      surface-container-high: "#2B2B28"
      surface-container-highest: "#343430"
      on-surface: "#F6F2E8"
      on-surface-muted: "#C4BEB3"
      on-surface-subtle: "#9B968C"
      outline: "#484843"
      outline-strong: "#7B766D"
      action: "#F6F2E8"
      on-action: "#171716"
      caret: "#F6F2E8"
      placeholder: "#AAA49A"
      selection: "#41413D"
      scrim: "rgba(0, 0, 0, 0.55)"
semantic-colors:
  status-light:
    error: "#B3261E"
    on-error: "#FFFFFF"
    success: "#047857"
    on-success: "#FFFFFF"
    warning: "#92400E"
    on-warning: "#FFFFFF"
    recording: "#B3261E"
    on-recording: "#FFFFFF"
  status-dark:
    error: "#FFB4AB"
    on-error: "#690005"
    success: "#6EE7B7"
    on-success: "#003824"
    warning: "#FFB95B"
    on-warning: "#4A2800"
    recording: "#FF8A80"
    on-recording: "#4A0006"
  syllable-light:
    one: "#047857"
    two: "#0369A1"
    three: "#7E22CE"
    four-plus: "#B91C1C"
  syllable-dark:
    one: "#6EE7B7"
    two: "#93C5FD"
    three: "#D8B4FE"
    four-plus: "#FDA4AF"
  rhyme-light:
    - "#B91C1C"
    - "#92400E"
    - "#166534"
    - "#0369A1"
    - "#6D28D9"
    - "#BE185D"
    - "#9A3412"
    - "#155E75"
    - "#047857"
    - "#7E22CE"
    - "#854D0E"
    - "#3F6212"
  rhyme-dark:
    - "#FCA5A5"
    - "#FCD34D"
    - "#86EFAC"
    - "#7DD3FC"
    - "#C4B5FD"
    - "#F9A8D4"
    - "#FDBA74"
    - "#67E8F9"
    - "#A7F3D0"
    - "#E9D5FF"
    - "#FEF08A"
    - "#BEF264"
typography:
  display-lg:
    font-family: "System Serif"
    font-size: 44px
    font-weight: 700
    line-height: 52px
  display-md:
    font-family: "System Serif"
    font-size: 40px
    font-weight: 700
    line-height: 48px
  headline-lg:
    font-family: "System Serif"
    font-size: 34px
    font-weight: 700
    line-height: 42px
  headline-md:
    font-family: "System Serif"
    font-size: 28px
    font-weight: 700
    line-height: 36px
  title-lg:
    font-family: "System Sans"
    font-size: 20px
    font-weight: 500
    line-height: 28px
  title-md:
    font-family: "System Sans"
    font-size: 16px
    font-weight: 600
    line-height: 24px
  body-lg:
    font-family: "System Sans"
    font-size: 16px
    font-weight: 400
    line-height: 24px
  lyric-body:
    font-family: "System Sans"
    font-size: 17px
    font-weight: 400
    line-height: 27px
  lyric-metadata:
    font-family: "System Sans"
    font-size: 13px
    font-weight: 400
    line-height: 16px
  body-md:
    font-family: "System Sans"
    font-size: 14px
    font-weight: 400
    line-height: 20px
  body-sm:
    font-family: "System Sans"
    font-size: 12px
    font-weight: 400
    line-height: 16px
  label-md:
    font-family: "System Sans"
    font-size: 12px
    font-weight: 500
    line-height: 16px
  caption-mono:
    font-family: "System Monospace"
    font-size: 12px
    font-weight: 400
    line-height: 16px
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
  phi-rhythm:
    tight: 8px
    related: 13px
    standard: 21px
    section: 34px
    primary: 55px
  screen-horizontal: 24px
  editor-horizontal: 21px
  settings-horizontal: 21px
  drawer-horizontal: 16px
  assistant-panel: 20px
  card-gap: 12px
  section-gap: 16px
  sheet-handle-area: 64px
  editor-bottom-rest: 300px
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
  full: 9999px
texture:
  authored-static-only: true
  paper: "Flat warm-ivory color with no rules, fibers, grain, or other texture."
  graphite-grain-opacity-max: 0.025
  redraw-rule: "Compose Graphite grain once per resolved size from cached deterministic drawing primitives or low-opacity gradients only; never use raster texture, or any texture bitmap, at runtime or as an asset; typing must not regenerate texture."
  adaptive-rule: "Remove texture under reduced transparency or increased contrast."
motion:
  fast: "160ms"
  disclosure: "200ms"
  standard: "260ms"
  settle: "420ms"
  easing-standard: "cubic-bezier(0.23, 1, 0.32, 1)"
  spring-settle: "response 420ms, damping 0.80"
  reduced-motion: "Remove app-owned travel and scale; honor live system changes."
  reading: "Typing, selection actions, provider-form changes, and keyboard changes are immediate; keep text stationary."
  loading: "Use one progress indicator and a static selection highlight; no shimmer, waves, or repeated skeleton pulses."
components:
  shared-writing-surface:
    appearances: "Ink is crisp; Paper is flat warm ivory; Graphite uses static grain."
    states: "default, reduced-transparency, increased-contrast"
  opaque-bordered-surface:
    fill: "appearance.surface or appearance.surface-container"
    border: "appearance.outline, 1dp Android / 1pt iOS"
    states: "rest, raised, focused, pressed, disabled"
  appearance-selector:
    options: "Ink, Paper, Graphite"
    geometry: "42dp visible track inside a 48dp minimum touch target on Android"
    states: "unselected, selected, pressed, focused, disabled"
  primary-action:
    fill: "appearance.action"
    foreground: "appearance.on-action"
    height: "55dp Android"
    states: "enabled, pointer-hover, pressed, focused, disabled, loading"
  writers-marks:
    elements: "UnBlock scribble, focused-title underline, saved flourish"
    rule: "Deterministic monochrome paths tied to real focus, save, or press state; omit transient motion when animations are disabled."
  analysis-color-exception:
    palettes: "semantic-colors rhyme-light/rhyme-dark and syllable-light/syllable-dark"
    states: "off, light-appearance, dark-appearance"
---

## 1. Product direction

Writers Block is a focused songwriting workspace whose visual identity comes from ink, paper, and the shipped black-and-white WB icon. The interface should feel like a quiet writing desk: clear editorial hierarchy, restrained neutral chrome, readable lyric text, and a powerful assistant close at hand.

The visual system has three authored appearances. Ink Editorial is the default and the canonical app identity. Paper Notebook adds a warm paper-and-pencil character. Graphite Night is the low-glare dark counterpart. Missing or invalid stored values always resolve to Ink Editorial.

Ordinary navigation, cards, controls, selected states, focus treatment, and primary actions use only the active appearance's neutral ink and paper tokens. Chroma is reserved for rhyme, syllable, success, warning, error, and active-recording meaning. A semantic color must never be reused as brand decoration.

The pencil icon, low UnBlock scribble, focused-title underline, and saved flourish form one restrained hand-made signature. Standard icons, the WB logo, text, and controls remain crisp. Do not add handwriting fonts, hand-drawn replicas of native controls, or ornamental sketch marks disconnected from interaction state.

## 2. Appearance and color

### Ink Editorial

Ink Editorial uses paper white (#FCFCF8), near-black ink (#050505), grayscale containers, thin neutral rules, square-to-soft geometry, serif song identity, and solid near-black actions. It is light, crisp, and closest to the WB icon. It is the launch and fallback appearance.

### Paper Notebook

Paper Notebook uses a flat warm ivory (#F3EEDF), graphite text (#302E2A), and opaque warm surfaces. It has no rules, fibers, grain, or other texture. Controls remain native and precisely drawn.

### Graphite Night

Graphite Night uses soft black paper (#171716), chalk-white text and actions (#F6F2E8), opaque charcoal surfaces, neutral borders, and restrained authored static grain. It is dark without becoming glossy or blue-tinted.

### Analysis presentation and semantic color

Ink Editorial and Paper Notebook use the semantic light palettes. Graphite Night uses the semantic dark palettes. The effective app appearance, never the operating-system theme by itself, selects the analysis, status, system-bar, caret, and selection contrast variant.

Analysis has two presentation styles. Color is the compatibility default: rhyme colors identify matching sound families, while syllable colors communicate counts of one, two, three, and four-or-more. Ink Marks is hue-independent: deterministic solid, dashed, dotted, and dash-dot underlines identify rhyme families, while regular, medium, semibold, and bold word weights communicate syllable counts. The two Ink Marks encodings coexist when both analyses are enabled, and text without an active analysis cue retains the normal lyric-body treatment.

Settings and help copy use presentation-neutral feature names such as Rhyme Families and Syllable Guide, then explain the currently selected Color or Ink Marks encoding. Success, warning, error, and recording colors continue to communicate state. These functional exceptions to monochrome chrome must remain stable across Android and iOS.

In Color mode, when Rhyme Families is on, rhyme-family color owns the word foreground and a simultaneous syllable cue uses an underline. When Rhyme Families is off and Syllable Guide is on, the syllable token may own the semibold word foreground. Never assign two competing semantic foreground colors to one word.

## 3. Typography, layout, and shape

Song titles, welcome headlines, and major writing identity use the native system serif. Lyrics and controls use the native system sans. Technical metadata and compact measurements use the native system monospace. No bundled display or handwriting font is part of this system.

Lyric text starts at the lyric-body token and keeps generous line height. The platform text-size setting is authoritative: type tokens are starting metrics, not fixed caps. Supporting text should remain one clear hierarchy step below controls without dropping below platform-readable sizes.

The editor is the primary workspace. It uses a fixed top toolbar, a full writing surface, 20px to 24px horizontal inset, a large title field, and a long bottom rest area so the last lyric line can settle above controls and keyboards. Assistant controls rise from the bottom on phones and persist beside the editor at regular iPad widths. At 1100pt and wider, iPad uses a collapsible 320pt songs sidebar, flexible editor, and 380pt assistant column. Narrower regular-width iPad layouts collapse the songs sidebar while preserving the editor and assistant; compact multitasking widths use the phone flow. The project drawer enters from the left and remains full height.

Spacing follows the 4px base and the visible 8, 12, 16, 20, 24, 32, and 48px rhythm. Major editor, assistant, and drawer relationships may use the inverse golden ratio before rounding to platform-friendly values. Safe areas, keyboards, readable measure, and minimum touch targets override proportional geometry.

The shape language is editorial and square-to-soft, not bubbly. Inner controls use 6px to 12px radii, repeated rows and cards use 12px to 16px, grouped sheets may use 18px to 22px, and floating actions may use the 28px pill. Drawers remain square to the screen edge.

Android dp and iOS pt values may differ where native feel requires it. Shipped platform token files define that unit conversion; they must preserve the relative hierarchy in this document.

## 4. Material, texture, depth, and motion

App-owned content surfaces are opaque. Large panels, cards, sheets, drawers, and settings groups use the active surface fill plus a one-unit neutral border. Depth comes from tonal separation, the border, and at most one restrained neutral shadow. Do not use decorative blur, translucent tint, accent glow, or stacked elevation on content.

Graphite Night may use authored static procedural grain only. Generate it exclusively from cached drawing primitives or low-opacity gradients, cached by resolved size and appearance. Do not use raster texture, or any texture bitmap, at runtime or as an asset. Do not use random values, timers, animated grain, or per-frame noise. Typing and caret movement must not invalidate texture generation.

Ink Editorial and Paper Notebook remain flat and untextured. Graphite grain stays at or below 2.5%. Texture is a background layer, clipped to its surface, and never overlays text or interactive content.

Motion must explain feedback, state, or spatial origin. Use the shared 160ms feedback/dismissal and 260ms occasional-surface tiers with ease-out timing. Native sheets retain platform timing, focus management, and gestures. Templates rise from the bottom and dismiss toward the bottom. Complete an exit before removing its surface; do not approximate completion with a fixed wall-clock delay. Appearance selection applies immediately.

Frequent writing controls, selection actions, provider-form swaps, and keyboard-driven changes apply immediately. Reading text stays stationary. A static highlight identifies the rewrite target; one progress indicator conveys loading. Do not add shimmer, waves, repeated skeleton pulses, or celebratory scale. Real recording amplitude, progress, and direct manipulation remain useful state feedback. Reduced Motion removes app-owned travel and scale and takes effect when the system setting changes. Texture never moves.

## 5. Components

These shared primitives are the required styling seams. Product screens must consume them instead of creating screen-local palettes, textures, borders, selectors, or action treatments.

### Shared writing surface

Use the shared writing surface for the editor, Welcome, Settings, assistant full-screen surfaces, Projects and Trash, Templates, and other large sheets.

- Default: fill the entire surface with appearance.background and place any Graphite texture draw behind content.
- Ink Editorial: render only the crisp base.
- Paper Notebook: render only the flat warm-ivory base color.
- Graphite Night: render cached, nonrandom low-opacity grain.
- Reduced Transparency or Increased Contrast: remove texture and retain the solid base.
- Text-size changes, typing, selection, caret movement, and scrolling must not regenerate the texture.

### Opaque bordered surface

This primitive is the single seam for cards, grouped settings, suggestion surfaces, rewrite surfaces, assistant panels, drawers, and sheets. The historical iOS liquidGlassSurface helper may remain as an API name, but for these appearances it must resolve to this opaque primitive.

- Rest: appearance.surface or appearance.surface-container with a one-unit appearance.outline border. Interactive control boundaries use appearance.outline-strong so they retain at least 3:1 contrast.
- Raised: move one tonal step toward surface-container-high and add at most one neutral shadow.
- Focused: preserve the native focus indicator and strengthen the border to appearance.outline-strong where the platform calls for it.
- Pressed: use the native pressed treatment or a neutral 8% to 12% state overlay; do not introduce a semantic hue.
- Disabled: retain structure, reduce emphasis using platform-native disabled opacity, and keep text readable.

System-owned chrome may keep its native neutral material behavior when legibility requires it. App-owned content never layers translucent material over an authored writing surface.

### Appearance selector

The Appearance selector is a native or already-established three-option segmented control labeled Ink, Paper, and Graphite. It is the sole appearance chooser and appears at the top of General settings on Android and near the top of Settings on iOS.

- Unselected: neutral transparent or low-container background with readable secondary ink.
- Selected: appearance.action fill with appearance.on-action text, or the platform's equivalent high-contrast selected segment.
- Pressed: native pressed feedback without delayed persistence.
- Focused: visible platform focus treatment; keyboard and switch-control navigation must identify the option.
- Disabled: use native disabled semantics and retain the selected-value announcement.

Selection updates the presented Settings surface and the editor behind it in the same transaction. It does not depend on provider credentials or the existing Save Settings action.

### Primary action

The primary action primitive is used for UnBlock, suggestion generation, and the highest-priority confirmation in a surface. It uses appearance.action and appearance.on-action.

- Enabled: solid neutral fill, native label/icon layout, and no accent glow.
- Pointer hover: apply a neutral 8% state overlay only on pointer-capable devices.
- Pressed: native pressed feedback or a neutral 12% overlay; preserve the control's dimensions.
- Focused: keep the native keyboard or switch-control focus indicator visible.
- Disabled: use the platform disabled state; do not communicate disabled state by color alone.
- Loading: preserve width and height, expose an accessible progress state, and keep the progress indicator legible on the action fill.

Secondary actions use an outline, a low-container fill, or a text treatment from the same neutral palette. Native Material 3, SwiftUI, and UIKit buttons, switches, sliders, pickers, fields, and sheets remain the implementation base.

### Analysis presentation

The shared analysis primitive owns rhyme and syllable visualization. It is the only content primitive allowed to cycle through multiple hues, and only while Color is selected.

- Off: lyric text uses appearance.on-background with the normal lyric-body weight.
- Color on a light appearance: use rhyme-light and syllable-light.
- Color on a dark appearance: use rhyme-dark and syllable-dark.
- Color with rhyme plus syllable: rhyme owns the foreground; syllable owns the underline.
- Ink Marks rhyme: use a deterministic solid, dashed, dotted, or dash-dot underline for each rhyme family.
- Ink Marks syllables: use regular for zero or unknown, then medium, semibold, and bold for increasing syllable buckets.
- Ink Marks rhyme plus syllables: the underline pattern and word weight render simultaneously; ordinary text stays normal weight.
- Status: use the corresponding light or dark error, success, warning, or recording pair.

Analysis and status colors never tint navigation, selection chrome, ordinary icons, primary actions, cards, or decorative backgrounds.

### Provider selection

Local is the first provider option and the default when no valid preference is stored. Gemini, OpenAI, and Claude follow it as explicit alternatives. Preserve any valid saved provider and its compatible model. Local setup remains available without an API key; missing local weights must lead to setup rather than an automatic cloud fallback.

### Screen-level mappings

The top bar uses background/surface and muted ink, with the song name and compact save status always readable. The lyric editor uses background, on-background, caret, and placeholder explicitly; UIKit-backed editing must receive those resolved values rather than inherit the device theme. UIKit owns ordinary text-selection fill because it exposes no supported per-text-view selection-background API; app-owned rewrite selection uses the resolved selection token explicitly.

Project rows, Settings groups, suggestion cards, and rewrite chips use the opaque bordered surface. Active rows use a stronger neutral container or border, not a decorative hue. The UnBlock pencil and scribble remain the only hand-marked treatment.

Suggestion text is a passive reading surface. Each result exposes **Use line** and **Keep for later** as separate native actions; keeping a result never edits lyrics. Insertion briefly marks the inserted text using a neutral highlight and offers **Undo**. The insertion feedback expires or clears on the next content edit so its Undo action cannot reverse unrelated typing.

The editor exposes a labeled **Focus** toggle with a clear exit state. Focus temporarily hides secondary controls, analysis markings, and the assistant while preserving their previous preferences and visibility for restoration. It keeps lyrics, selection, save feedback, and the exit control available. The tablet assistant control names its visible open or close action. Focus changes apply immediately. Editor geometry changes directly so lyrics do not travel or animate while reflowing; typing and text decoration remain stationary.


## 6. Platform behavior and persistence

### Android

Android uses Material 3 components with three authored ColorSchemes, restrained shared Shapes, and a LocalAppAppearance value at the root. Wallpaper-derived color adaptation is disabled because it would violate the authored monochrome contract.

AppAppearance has enum cases INK, PAPER, and GRAPHITE with stable serialized values ink, paper, and graphite. ProjectRepository persists the value under the Preferences DataStore key app_appearance. This key is appearance-specific and must never reuse CURRENT_THEME_KEY, which stores the song's lyrical theme. Missing or invalid values resolve to INK.

MainViewModel owns the loaded appearance, exposes one immediate setter, and leaves a successfully selected in-memory appearance visible if persistence later fails. RhymeAITheme receives the appearance above the rest of the composition. Runtime system-bar icon brightness follows AppAppearance.isDark. The authored startup splash uses Ink until persisted state is available.

### iOS

iOS uses AppAppearanceStyle raw values ink, paper, and graphite. The app root stores the raw value with @AppStorage under appAppearanceStyle, resolves invalid values to ink, injects the resolved style through the SwiftUI environment, and publishes the binding used by Settings.

Ink Editorial and Paper Notebook request the light color scheme. Graphite Night requests the dark color scheme. UIKit lyric editing receives explicit foreground, caret, and placeholder colors from the same resolved palette; native selection fill remains platform-owned, while app-owned rewrite selection uses the resolved selection token.

SwiftUI and UIKit controls remain native. App-owned panels use the opaque bordered surface. Native platform material may appear only in system-owned chrome, must remain neutral, and must not replace the authored paper or graphite surface.

On both platforms an appearance change is immediate, persistent, offline, and isolated from song data, cloud backup data, provider credentials, and the song-level lyrical theme field.

## 7. Accessibility and adaptive constraints

Accessibility outranks texture and aesthetic preference.

- Contrast: base foreground/background pairs must meet WCAG 2.2 AA: 4.5:1 for normal text, 3:1 for large text, icons, focus indicators, and control boundaries. Validate semantic colors against the effective light or dark base.
- Increased Contrast: remove texture, use outline-strong for important boundaries, and avoid low-opacity-only states.
- Reduced Transparency: remove texture and resolve every app-owned surface to its opaque base. No information may depend on translucency.
- Reduced Motion: remove nonessential travel, spring overshoot, and decorative crossfades. Preserve immediate state feedback and spatial continuity without animation.
- Text size: support Android font scaling and iOS Dynamic Type through accessibility sizes. Controls and preview cards reflow vertically before truncating labels; fixed heights must not clip text.
- Touch: preserve at least 48dp targets on Android and 44pt targets on iOS, including segmented options, preview cards, help affordances, and close controls.
- Screen readers: provide concise control labels, selected values, progress state, and grouping. Do not duplicate visible labels as redundant descriptions.
- Keyboard and switch access: preserve native traversal order and visible focus for selector options, buttons, fields, sheets, and drawers.
- Color independence: controls and status messages use text, icons, shape, or state semantics in addition to color. Analysis color overlays never alter the underlying lyric content or reading order.
- Edge to edge: safe-area and keyboard handling remain intact in every appearance. System bars must retain readable icons against the resolved appearance.

Test the writing flow with low vision, motion sensitivity, large text, screen-reader use, temporary one-handed use, and bright-light or low-light situational constraints. A failure that blocks writing, selecting an appearance, or recovering an error blocks completion unless explicitly accepted as design debt.

## 8. Do, do not, verification, and debt

Do keep the lyric editor visually quiet and let typography carry the hierarchy.

Do use Ink Editorial as the default and fallback.

Do use shared semantic tokens and primitives before screen-specific styling.

Do preserve native behavior and geometry while aligning both platforms to the same authored appearance.

Do keep semantic analysis and status colors stable and contrast-aware.

Do verify immediate switching, relaunch persistence, keyboard/caret contrast, system bars, Settings, assistant, projects, and the editor in all three appearances.

Do not add decorative chroma to ordinary chrome.

Do not enable wallpaper-derived palettes for authored appearances.

Do not put translucent or blurred app content over paper.

Do not use raster paper or graphite texture, or any texture bitmap, at runtime or as an asset. Do not add animated grain, random per-frame noise, or texture above glyphs.

Do not replace native buttons, switches, sliders, pickers, fields, or sheets with hand-drawn replicas.

Do not let appearance state modify a project, provider configuration, cloud data, or the lyrical theme field.

Capture Android and iOS editor and Settings screenshots for Ink Editorial, Paper Notebook, and Graphite Night after the final implementation edit. Visual sign-off requires checking all interaction states, text-size reflow, reduced motion, reduced transparency, increased contrast, semantic colors, and texture placement on the actual built surfaces.

Accepted design debt at contract approval: none. Platform startup constraint: the static launch surface is Ink because persisted appearance state is not available during earliest startup; the runtime surface must adopt the stored appearance as soon as root state resolves.
