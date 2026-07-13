# Monochrome and Paper Appearance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship persistent Ink Editorial, Paper Notebook, and Graphite Night appearances across the native Android and iOS apps, with Ink as the default and color retained only for semantic analysis/status information.

**Architecture:** Each platform gets one small persisted appearance enum at the app root, one semantic palette/surface seam, and an immediate Settings selector. Existing screens continue to use native Material 3 and SwiftUI/UIKit controls; shared theme/surface primitives carry most of the redesign, while direct system-theme and indigo call sites are migrated to the effective app appearance.

**Tech Stack:** Kotlin 2.3.20, Jetpack Compose Material 3, Preferences DataStore, Swift 6, SwiftUI, UIKit bridge, `@AppStorage`, Swift Testing, XCTest.

## Global Constraints

- Ink Editorial is the default for missing or invalid persisted values.
- Paper Notebook is warm ivory with subtle static fibers/rules; Graphite Night is soft black with subtle static grain.
- Rhyme, syllable, success, warning, and error colors remain semantic exceptions.
- Do not reuse Android `CURRENT_THEME_KEY` or either platform's song-level `theme` property.
- Disable Android Material You dynamic color for these authored appearances.
- Do not add handwriting fonts, raster paper textures, animated grain, or replacement implementations for native buttons/switches/sliders.
- Texture must remain behind content and must not regenerate per frame while typing.
- Preserve all existing dirty-worktree accessibility, local-model, AI recovery, and finetune changes.
- Do not commit or push unless the user explicitly asks.
- Execute Task 5 before Tasks 1-4: the updated `DESIGN.md` is the source of truth for every appearance token and primitive used by implementation.
- The authored Ink splash is intentionally static; persisted Graphite/Paper applies as soon as app state loads.

## File Structure

### Android

- Create `android/app/src/main/kotlin/com/rhymeai/app/data/model/AppAppearance.kt`: stable persisted appearance values and fallback behavior.
- Create `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/WritingSurface.kt`: cached/static writing-surface modifier.
- Create `android/app/src/main/kotlin/com/rhymeai/app/ui/components/AppearanceSelector.kt`: compact three-style selector and canonical previews.
- Create `android/app/src/test/kotlin/com/rhymeai/app/data/model/AppAppearanceTest.kt`: serialization/fallback contract.
- Create `android/app/src/androidTest/kotlin/com/rhymeai/app/AppearancePersistenceInstrumentedTest.kt`: DataStore round-trip contract.
- Modify `ProjectRepository.kt`, `MainViewModel.kt`, and `MainActivity.kt`: persistence, app state, root theme, Settings bridge.
- Modify `Color.kt` and `Theme.kt`: three authored Material color schemes and removal of dynamic color.
- Modify `SettingsDialog.kt`: immediate three-style appearance selector.
- Modify `SafeArea.kt`, `RhymeHighlightedText.kt`, `SyllableColoredText.kt`, `AssistantPanelHelp.kt`, and `EditorScreen.kt`: use effective appearance instead of the OS theme.
- Modify `WelcomeScreen.kt`, `SegmentedControl.kt`, `SuggestionCard.kt`, and `RewriteChipBar.kt`: shared monochrome chrome and writing background.

### iOS

- Create `Writers Block/Writers Block/Support/AppAppearance.swift`: persisted enum, environment keys, semantic palette, and reusable writing background.
- Create `Writers Block/Writers Block/Views/AppearanceSettingsSection.swift`: native selector and canonical previews.
- Create `Writers Block/Writers BlockTests/AppAppearanceTests.swift`: fallback and color-scheme contract.
- Create `Writers Block/Writers BlockUITests/AppAppearanceUITests.swift`: switching, persistence, and screenshot walkthrough.
- Modify `Writers_BlockApp.swift`: root `@AppStorage`, environment injection, preferred color scheme, and neutral tint.
- Modify `LiquidGlassSupport.swift`: appearance-aware opaque paper/graphite/ink surfaces.
- Modify `SettingsView.swift`: immediate three-style appearance selector and appearance background.
- Modify `LyricsTextView.swift`: neutral adaptive caret/placeholder/text colors.
- Modify `WelcomeView.swift`, `EditorView.swift`, `AssistantPanelView.swift`, `ProjectsDrawerView.swift`, `ProjectsView.swift`, `TrashBinView.swift`, `TemplatesView.swift`, and shared editor components containing indigo chrome: replace decorative accent use with semantic appearance tokens.

### Shared documentation and verification

- Modify `DESIGN.md`: replace the stale indigo/glass contract with the approved appearance system.
- Modify `.gitignore`: ignore `.superpowers/` brainstorm artifacts.
- Use existing Android/iOS unit/UI test targets and simulator/emulator tooling; do not introduce a snapshot framework.

---

### Task 1: Android Appearance Model and Persistence

**Files:**
- Create: `android/app/src/main/kotlin/com/rhymeai/app/data/model/AppAppearance.kt`
- Create: `android/app/src/test/kotlin/com/rhymeai/app/data/model/AppAppearanceTest.kt`
- Create: `android/app/src/androidTest/kotlin/com/rhymeai/app/AppearancePersistenceInstrumentedTest.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/data/repository/ProjectRepository.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/MainViewModel.kt`

**Interfaces:**
- Produces: `AppAppearance`, `ProjectRepository.appearanceFlow`, `ProjectRepository.saveAppearance`, `MainViewModel.appAppearance`, and `MainViewModel.setAppAppearance`.
- Consumes: existing Preferences DataStore and `viewModelScope` patterns.

- [ ] **Step 1: Write the failing enum contract test**

```kotlin
class AppAppearanceTest {
    @Test fun defaultsToInkForMissingOrUnknownValues() {
        assertEquals(AppAppearance.INK, AppAppearance.fromStorage(null))
        assertEquals(AppAppearance.INK, AppAppearance.fromStorage("neon"))
    }

    @Test fun roundTripsEveryStableStorageValue() {
        AppAppearance.entries.forEach { appearance ->
            assertEquals(appearance, AppAppearance.fromStorage(appearance.storageValue))
        }
    }
}
```

- [ ] **Step 2: Run the focused test and confirm it fails before implementation**

Run from `android/`:

```bash
./gradlew :app:testDebugUnitTest --tests com.rhymeai.app.data.model.AppAppearanceTest
```

Expected: compilation failure because `AppAppearance` does not exist.

- [ ] **Step 3: Add the minimal stable appearance model**

```kotlin
enum class AppAppearance(
    val storageValue: String,
    val displayName: String
) {
    INK("ink", "Ink"),
    PAPER("paper", "Paper"),
    GRAPHITE("graphite", "Graphite");

    val isDark: Boolean get() = this == GRAPHITE

    companion object {
        fun fromStorage(value: String?): AppAppearance =
            entries.firstOrNull { it.storageValue == value } ?: INK
    }
}
```

- [ ] **Step 4: Add a new DataStore key, flow, and immediate save path**

```kotlin
private val APP_APPEARANCE_KEY = stringPreferencesKey("app_appearance")

val appearanceFlow: Flow<AppAppearance> = context.dataStore.data.map { prefs ->
    AppAppearance.fromStorage(prefs[APP_APPEARANCE_KEY])
}

suspend fun saveAppearance(appearance: AppAppearance) {
    context.dataStore.edit { prefs ->
        prefs[APP_APPEARANCE_KEY] = appearance.storageValue
    }
}
```

- [ ] **Step 5: Own appearance state in `MainViewModel` and load it before showing the start menu**

```kotlin
var appAppearance by mutableStateOf(AppAppearance.INK)
    private set

fun setAppAppearance(appearance: AppAppearance) {
    appAppearance = appearance
    viewModelScope.launch { repo.saveAppearance(appearance) }
}
```

Inside the existing initialization coroutine, assign `appAppearance = repo.appearanceFlow.first()` before `showStartMenu = true`.

- [ ] **Step 6: Re-run the focused test and compile Kotlin**

```bash
./gradlew :app:testDebugUnitTest --tests com.rhymeai.app.data.model.AppAppearanceTest
./gradlew :app:compileDebugKotlin
```

Expected: both commands exit 0.

- [ ] **Step 7: Add and run the Android DataStore round-trip test**

Use an isolated instrumented-test preferences state, save each appearance, assert the real repository flow emits it, and restore Ink in teardown. Do not test DataStore from the JVM target.

### Task 2: Android Semantic Theme, Paper Surface, and Settings UI

**Files:**
- Create: `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/WritingSurface.kt`
- Create: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/AppearanceSelector.kt`
- Create: `android/app/src/test/kotlin/com/rhymeai/app/ui/theme/AppearanceThemeTest.kt`
- Create: `android/app/src/androidTest/kotlin/com/rhymeai/app/AppearanceUiTest.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/MainActivity.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/Color.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/Theme.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SettingsDialog.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SafeArea.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/RhymeHighlightedText.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SyllableColoredText.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/AssistantPanelHelp.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/WelcomeScreen.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SegmentedControl.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SuggestionCard.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/RewriteChipBar.kt`
- Modify: `android/app/src/main/res/values/colors.xml`
- Modify: `android/app/src/main/res/values-night/colors.xml`
- Modify: `android/app/src/main/res/values-v31/colors.xml`
- Modify: `android/app/src/main/res/values-night-v31/colors.xml`

**Interfaces:**
- Consumes: `AppAppearance` from Task 1.
- Produces: `LocalAppAppearance`, `Modifier.appWritingSurface()`, and three complete Material `ColorScheme`s.

- [ ] **Step 1: Replace dynamic color with authored monochrome schemes**

First write a focused theme contract test that asserts each appearance selects its canonical background/action palette and that Graphite alone uses the dark analysis palette. Run it and confirm the expected missing-theme-interface failure before production edits.

Use these base tokens:

```kotlin
val Ink = Color(0xFF050505)
val PaperWhite = Color(0xFFFCFCF8)
val PaperIvory = Color(0xFFF3EEDF)
val Graphite = Color(0xFF171716)
val GraphiteSurface = Color(0xFF232321)
val Pencil = Color(0xFF302E2A)
```

Define Ink and Paper as light schemes with near-black `primary`; define Graphite as a dark scheme with warm-white `primary`. Keep existing semantic error, success, rhyme, and syllable tokens.

- [ ] **Step 2: Publish the effective appearance from the root theme**

```kotlin
val LocalAppAppearance = staticCompositionLocalOf { AppAppearance.INK }

@Composable
fun RhymeAITheme(
    appearance: AppAppearance = AppAppearance.INK,
    content: @Composable () -> Unit
) {
    val scheme = when (appearance) {
        AppAppearance.INK -> InkColorScheme
        AppAppearance.PAPER -> PaperColorScheme
        AppAppearance.GRAPHITE -> GraphiteColorScheme
    }
    CompositionLocalProvider(LocalAppAppearance provides appearance) {
        MaterialTheme(colorScheme = scheme, typography = RhymeTypography) {
            ProvideAccessibleAnimations(content)
        }
    }
}
```

Hoist the existing `MainViewModel` above `RhymeAITheme` in `MainActivity`, pass `viewModel.appAppearance` to the theme, and pass `currentAppearance` plus `onAppearanceChange = viewModel::setAppAppearance` into Settings. Update status/navigation-bar icon brightness from `viewModel.appAppearance.isDark` and preserve the current accessibility overlay and navigation modifier changes. Author all four `splash_material_surface` resources as Ink because persisted appearance is not available during the static splash.

- [ ] **Step 3: Add one cached/static writing-surface modifier**

```kotlin
@Composable
fun Modifier.appWritingSurface(): Modifier {
    val appearance = LocalAppAppearance.current
    val base = MaterialTheme.colorScheme.background
    return background(base).drawWithCache {
        val ruleColor = Pencil.copy(alpha = 0.055f)
        onDrawBehind {
            if (appearance == AppAppearance.PAPER) {
                var y = 28.dp.toPx()
                while (y < size.height) {
                    drawLine(ruleColor, Offset(0f, y), Offset(size.width, y), 1.dp.toPx())
                    y += 28.dp.toPx()
                }
            }
        }
    }
}
```

Use it on the editor, welcome, Settings, projects/trash, templates, export, word-inspector, and assistant large-surface roots. Keep all text/content above the draw layer. Use deterministic cached drawing primitives/gradients only; no texture bitmap, random values, timer, or per-frame regeneration. Remove texture when Android high-text-contrast mode is active.

- [ ] **Step 4: Make Settings apply appearance immediately**

Add parameters:

```kotlin
currentAppearance: AppAppearance,
onAppearanceChange: (AppAppearance) -> Unit,
```

At the top of General settings render `Text("Appearance")`, a three-option `SlidingSegmentedControl`, and three small neutral preview swatches. The selector calls `onAppearanceChange(AppAppearance.entries[index])` directly and does not touch the pinned Save button.

- [ ] **Step 5: Remove device-theme divergence**

At every direct `isSystemInDarkTheme()` call, use:

```kotlin
val isDark = LocalAppAppearance.current.isDark
```

Use `isDark` for system-bar icons and for selecting the existing light/dark rhyme and syllable contrast palettes.

- [ ] **Step 6: Convert decorative chrome through shared semantic tokens**

Keep existing native controls and geometry. Replace authored indigo/purple decorative colors with `MaterialTheme.colorScheme.primary`, `onPrimary`, `surfaceContainer*`, `outline`, and `onSurfaceVariant`. Do not change semantic error/success/rhyme/syllable colors.

- [ ] **Step 7: Run focused Android verification**

Before the final build, add a focused Compose UI test that opens Settings, selects Ink/Paper/Graphite, verifies the selected label changes immediately, relaunches, and verifies persistence. Reuse the existing test screenshot helper or its established output directory for final visual evidence.

```bash
./gradlew :app:testDebugUnitTest
./gradlew :app:lintDebug
./gradlew :app:assembleDebug
```

Expected: all commands exit 0; no new lint errors.

### Task 3: iOS Appearance Model, Root State, and Tests

**Files:**
- Create: `Writers Block/Writers Block/Support/AppAppearance.swift`
- Create: `Writers Block/Writers BlockTests/AppAppearanceTests.swift`
- Modify: `Writers Block/Writers Block/Writers_BlockApp.swift`

**Interfaces:**
- Produces: `AppAppearanceStyle`, `AppAppearancePalette`, resolved-style and appearance-binding environment values, and `AppWritingBackground`.
- Consumes: SwiftUI `@AppStorage` and `ColorScheme`.

- [ ] **Step 1: Write the failing pure appearance tests**

```swift
struct AppAppearanceTests {
    @Test func unknownValuesFallBackToInk() {
        #expect(AppAppearanceStyle.resolve(nil) == .ink)
        #expect(AppAppearanceStyle.resolve("neon") == .ink)
    }

    @Test func graphiteIsTheOnlyDarkAppearance() {
        #expect(AppAppearanceStyle.ink.preferredColorScheme == .light)
        #expect(AppAppearanceStyle.paper.preferredColorScheme == .light)
        #expect(AppAppearanceStyle.graphite.preferredColorScheme == .dark)
    }
}
```

- [ ] **Step 2: Run the focused iOS test and confirm it fails before implementation**

Use the booted iPhone 17 Pro with Xcode 27 beta:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6' -only-testing:'Writers BlockTests/AppAppearanceTests'
```

Expected: compilation failure because `AppAppearanceStyle` does not exist.

- [ ] **Step 3: Add the stable enum, environment value, and adaptive neutral action colors**

```swift
enum AppAppearanceStyle: String, CaseIterable, Identifiable {
    case ink, paper, graphite

    static let storageKey = "appAppearanceStyle"
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var preferredColorScheme: ColorScheme { self == .graphite ? .dark : .light }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .ink
    }
}

private struct AppAppearanceEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppAppearanceStyle = .ink
}

extension EnvironmentValues {
    var appAppearanceStyle: AppAppearanceStyle {
        get { self[AppAppearanceEnvironmentKey.self] }
        set { self[AppAppearanceEnvironmentKey.self] = newValue }
    }
}
```

Define one semantic palette per appearance so Ink/Paper use black-on-light and Graphite uses warm white-on-charcoal. Include canvas, surface, raised surface, primary/secondary ink, outline, action/on-action, caret, placeholder, and selection tint. Add a second environment value carrying `Binding<AppAppearanceStyle>` from the app root; Settings must consume this binding rather than create another `@AppStorage` owner.

- [ ] **Step 4: Bind the app root to `@AppStorage`**

```swift
@AppStorage(AppAppearanceStyle.storageKey)
private var appearanceRawValue = AppAppearanceStyle.ink.rawValue

private var appearance: AppAppearanceStyle {
    AppAppearanceStyle.resolve(appearanceRawValue)
}
```

Apply `.environment(\.appAppearanceStyle, appearance)`, the root-owned appearance binding, `.preferredColorScheme(appearance.preferredColorScheme)`, and `.tint(appearance.palette.action)` to the root group containing `ContentView`. Preserve the current Dynamic Type and SwiftData wiring.

- [ ] **Step 5: Add a reusable static background**

`AppWritingBackground` renders the base paper/graphite/ink color, deterministic low-opacity rules/fibers for Paper, and deterministic low-opacity grain for Graphite. It must use cached/static SwiftUI drawing primitives or gradients only: no texture bitmap, timers, random values, animated grain, or blur. Remove texture when Reduce Transparency or Increased Contrast is enabled.

- [ ] **Step 6: Re-run the focused tests and build**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6' -only-testing:'Writers BlockTests/AppAppearanceTests'
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild build -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6'
```

Expected: both commands exit 0.

### Task 4: iOS Appearance-Aware Surfaces and Settings

**Files:**
- Create: `Writers Block/Writers Block/Views/AppearanceSettingsSection.swift`
- Create: `Writers Block/Writers BlockUITests/AppAppearanceUITests.swift`
- Modify: `Writers Block/Writers Block/Views/LiquidGlassSupport.swift`
- Modify: `Writers Block/Writers Block/Views/SettingsView.swift`
- Modify: `Writers Block/Writers Block/Components/LyricsTextView.swift`
- Modify: `Writers Block/Writers Block/Components/RhymeHighlightedText.swift`
- Modify: `Writers Block/Writers Block/Components/SyllableColoredText.swift`
- Modify: `Writers Block/Writers Block/Views/AssistantPanelHelpView.swift`
- Modify: `Writers Block/Writers Block/Views/WelcomeView.swift`
- Modify: `Writers Block/Writers Block/Views/EditorView.swift`
- Modify: `Writers Block/Writers Block/Views/AssistantPanelView.swift`
- Modify: `Writers Block/Writers Block/Views/ProjectsDrawerView.swift`
- Modify: `Writers Block/Writers Block/Views/ProjectsView.swift`
- Modify: `Writers Block/Writers Block/Views/TrashBinView.swift`
- Modify: `Writers Block/Writers Block/Views/TemplatesView.swift`
- Modify: `Writers Block/Writers Block/Components/FloatingMicButton.swift`
- Modify: `Writers Block/Writers Block/Components/WordInspectorSheetView.swift`
- Modify: `Writers Block/Writers Block/Components/SuggestionCardView.swift`
- Modify: `Writers Block/Writers Block/Components/ExportSheet.swift`
- Modify: `Writers Block/Writers Block/Components/BeatGridPreviewView.swift`
- Modify: `Writers Block/Writers Block/Components/RhymeSchemeDisplayView.swift`
- Modify: `Writers Block/Writers Block/Components/RewriteSheet.swift`
- Modify: `Writers Block/Writers Block/Components/RewriteChipBar.swift`

**Interfaces:**
- Consumes: `AppAppearanceStyle`, `AppAppearancePalette`, the root-owned appearance binding, and `AppWritingBackground` from Task 3.
- Produces: immediate appearance selection and neutral shared surfaces across all screens.

- [ ] **Step 1: Make the shared surface seam opaque and appearance-aware**

Add `@Environment(\.appAppearanceStyle)` to `LiquidGlassSurfaceModifier`. For all three authored appearances, render an opaque semantic surface plus a one-point neutral border. Paper uses warm ivory, Ink uses paper white, and Graphite uses charcoal. Ignore decorative tint colors at the shared seam; keep semantic status colors in foreground content.

```swift
content
    .background(
        appearance.surfaceColor,
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    )
    .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(appearance.borderColor, lineWidth: 1)
    )
```

- [ ] **Step 2: Add an immediate Appearance section at the top of Settings**

Consume the root-owned `Binding<AppAppearanceStyle>` from the environment. Render a native segmented `Picker` for all three cases plus compact preview cards in `AppearanceSettingsSection`. Insert it before `providerSection`. Remove the indigo/teal/pink Settings background gradients and use `AppWritingBackground`. Give the picker the accessibility identifier `appearancePicker`; selection persists immediately and never waits on Save.

- [ ] **Step 3: Give the UIKit lyric editor resolved neutral colors**

Set `UITextView.tintColor`, foreground, placeholder, and selection-related tint from the resolved `AppAppearancePalette` in both `makeUIView` and `updateUIView`, and do not regress the existing Dynamic Type changes.

- [ ] **Step 4: Migrate direct decorative accent call sites**

For the files listed above, replace decorative `.indigo`, `.purple`, `.teal`, and `.pink` chrome with the resolved palette action/on-action colors, `.primary`, `.secondary`, or appearance surface/border tokens. Keep `.red`, `.orange`, `.green`, rhyme palettes, and syllable palettes only where they communicate state or analysis. Analysis light/dark selection follows `AppAppearanceStyle.usesDarkAnalysisPalette`, never the device theme alone.

- [ ] **Step 5: Apply `AppWritingBackground` to major screen roots**

Use it in Welcome, Editor, Settings, Projects/Trash, Templates, and assistant full-screen surfaces. Do not place the texture above text or inside every control.

- [ ] **Step 6: Add the appearance UI walkthrough, then run focused tests and build**

Write a focused UI test that launches with the existing in-memory test configuration, switches Ink → Paper → Graphite through `appearancePicker`, captures Settings and editor for each, types lyrics with the keyboard/caret visible, opens Assistant and Projects, terminates/relaunches, and verifies Graphite persistence. The test must produce inspectable `.xcresult` PNG attachments.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6' -only-testing:'Writers BlockTests/AppAppearanceTests'
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6' -only-testing:'Writers BlockUITests/AppAppearanceUITests'
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild build -project "Writers Block/Writers Block.xcodeproj" -scheme "Writers Block" -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6'
```

Expected: focused appearance tests and build exit 0 with no new warnings in changed files. The pre-implementation full iOS suite has unrelated SwiftData/CoreData and Gemini debug-key failures; report those baseline failures without changing or hiding them.

### Task 5: Design Contract and Repository Hygiene

**Files:**
- Modify: `DESIGN.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: final token values and behavior from Tasks 2 and 4.
- Produces: one authoritative design contract and a clean worktree view.

- [ ] **Step 1: Replace stale brand language and palette tokens in `DESIGN.md`**

Document the three appearances, Ink default, monochrome chrome rule, semantic color exceptions, static texture/performance limit, platform persistence keys, and native-control rule. Section 5 must name the shared writing surface, opaque bordered surface, appearance selector states, primary action states, and analysis-color exceptions before product-screen code uses them. Remove claims that indigo/purple, Material You dynamic color, or colored glass are the canonical identity.

- [ ] **Step 2: Ignore visual-companion working files**

Add exactly this repository-local ignore entry:

```gitignore
.superpowers/
```

- [ ] **Step 3: Check documentation consistency**

```bash
rg -n 'canonical palette is near-black with indigo|Material You dynamic color|indigo, purple' DESIGN.md
rg -n 'Ink Editorial|Paper Notebook|Graphite Night|semantic' DESIGN.md
```

Expected: stale-contract search returns no matches; new-contract search returns the documented appearance sections.

### Task 6: Cross-Platform Build and Manual QA Gate

**Files:**
- Verify only; change implementation files only to fix observed defects.

**Interfaces:**
- Consumes: completed Android and iOS implementations.
- Produces: build/test logs and screenshots proving all three appearances work.

- [ ] **Step 1: Run the repository Android verification set**

From `android/`:

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew check
./gradlew lint
./gradlew detekt
./gradlew spotlessApply
./gradlew :app:assembleDebug
```

Skip `detekt` or `spotlessApply` only when the task is not configured. Run `connectedDebugAndroidTest` when an emulator is available.

- [ ] **Step 2: Run the repository iOS verification set**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export IOS_DESTINATION='platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6'
xcodebuild -list -project "Writers Block/Writers Block.xcodeproj"
xcrun simctl list devices available
./scripts/verify.sh
```

The destination override is required because only iOS 27.0 is installed and the script's default iOS 26.5 destination is unavailable.

- [ ] **Step 3: Drive Android through the user flow**

Start `Pixel_10_Pro_XL`, launch the debug APK, open Settings, switch Ink → Paper → Graphite, and capture editor and Settings screenshots for each. Relaunch after Graphite and verify it persists. Type lyrics, open Assistant and Projects, and verify caret/system-bar contrast and semantic rhyme/syllable colors. Reuse `NewFeatureUiTest`'s screenshot helper, which writes to `/sdcard/Pictures/RhymeAI-Test/`.

- [ ] **Step 4: Drive iOS through the user flow**

Launch on the booted iPhone 17 Pro (`9421D79B-4889-41C8-A355-815D4C11FDF6`), open Settings, switch Ink → Paper → Graphite, and capture editor and Settings screenshots for each. Relaunch after Graphite and verify it persists. Type lyrics, open Assistant and Projects, and verify caret/system-bar contrast and semantic rhyme/syllable colors. Reuse the existing XCTest attachment helper and export the PNG attachments from its `.xcresult` bundle.

- [ ] **Step 5: Compare platforms and fix observed defects**

Confirm the same appearance names, ordering, defaults, semantic-color exceptions, and paper texture restraint. Fix any mismatch before completion.

- [ ] **Step 6: Run final review and debugging gates**

Run the required post-implementation review and runtime-debugging audits. Record three concrete runtime hypotheses and the evidence that confirms or rejects each. Resolve every actionable finding, then rerun focused verification.
