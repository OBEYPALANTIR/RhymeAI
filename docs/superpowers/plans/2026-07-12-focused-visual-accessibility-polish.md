# Focused Visual and Accessibility Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve compact editor chrome, Graphite contrast, welcome-card layout, and add a persistent cross-platform Color/Ink Marks analysis presentation.

**Architecture:** Analysis presentation is independent app preference state injected at each platform root, then consumed by token-driven analysis renderers and Settings previews. Compact-header, welcome, and contrast changes stay inside existing native views/components; no navigation or song-data architecture changes are introduced.

**Tech Stack:** SwiftUI, Swift AttributedString, Swift Testing, XCTest/XCUITest, Jetpack Compose Material 3, Preferences DataStore, Kotlin/JUnit, Compose UI testing, Android emulator, iOS Simulator.

## Global Constraints

- Color remains the default analysis presentation and must remain output-compatible with current behavior.
- Ink Marks uses authored appearance ink only: rhyme family is solid/dashed/dotted/dash-dot underline; syllable count is regular/medium/semibold/bold for 1/2/3/4+.
- Unknown stored values resolve to Color without changing song, appearance, provider/model, or API-key state.
- Normal text contrast is at least 4.5:1; large text and interactive boundaries are at least 3:1.
- Keep iOS 44pt and Android 48dp minimum interactive targets.
- Do not add raster textures, custom fonts, per-frame randomness, decorative motion, geometry polling, or preference reads in typing/render hot paths.
- Preserve the existing dirty worktree and unrelated local-model, motion, appearance, backup, and finetune changes.
- Do not commit or push unless the user explicitly authorizes it. Task boundaries end with tests and `git diff --check`, not commits.

---

## File Map

### New files

- `Writers Block/Writers Block/Support/AnalysisPresentationStyle.swift` — iOS enum, persistence key, deterministic pattern/weight helpers, and environment keys.
- `Writers Block/Writers Block/Views/AnalysisStyleSettingsSection.swift` — iOS selector, live preview, and legend.
- `Writers Block/Writers BlockTests/AnalysisPresentationStyleTests.swift` — iOS state and encoding unit tests.
- `android/app/src/main/kotlin/com/rhymeai/app/data/model/AnalysisPresentation.kt` — Android enum and stable fallback.
- `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/AnalysisPresentation.kt` — Android composition local and deterministic pattern/weight helpers.
- `android/app/src/main/kotlin/com/rhymeai/app/ui/components/AnalysisStyleSelector.kt` — Android selector, live preview, and legend.
- `android/app/src/test/kotlin/com/rhymeai/app/data/model/AnalysisPresentationTest.kt` — Android enum tests.
- `android/app/src/test/kotlin/com/rhymeai/app/ui/theme/AnalysisInkMarksTest.kt` — Android deterministic encoding tests.

### Existing files to modify

- `Writers Block/Writers Block/Writers_BlockApp.swift` — root `@AppStorage`, binding, and environment injection.
- `Writers Block/Writers Block/Views/SettingsView.swift` — place Analysis Style immediately after Appearance.
- `Writers Block/Writers Block/Components/RhymeHighlightedText.swift` — Color/Ink Marks attributed output.
- `Writers Block/Writers Block/Components/SyllableColoredText.swift` — Ink Marks syllable weights.
- `Writers Block/Writers Block/Views/EditorView.swift` — compact counter branch, title priority, authored top-bar colors.
- `Writers Block/Writers Block/Views/WelcomeView.swift` — resilient card text layout and authored secondary colors.
- `Writers Block/Writers Block/Views/AssistantPanelView.swift` — remove low-contrast Graphite opacity stacking.
- `Writers Block/Writers BlockUITests/AppAppearanceUITests.swift` — analysis persistence and fresh visual states.
- `Writers Block/Writers BlockUITests/Writers_BlockUITests.swift` — long-title and welcome Dynamic Type checks.
- `android/app/src/main/kotlin/com/rhymeai/app/data/repository/ProjectRepository.kt` — analysis preference flow/save.
- `android/app/src/main/kotlin/com/rhymeai/app/MainViewModel.kt` — loaded analysis state and setter.
- `android/app/src/main/kotlin/com/rhymeai/app/MainActivity.kt` — root state/theme wiring and Settings callbacks.
- `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/Theme.kt` — publish analysis presentation through composition local.
- `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SettingsDialog.kt` — render selector in General settings.
- `android/app/src/main/kotlin/com/rhymeai/app/ui/components/RhymeHighlightedText.kt` — Ink Marks attributed text and patterned underline spans.
- `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SyllableColoredText.kt` — shared word-range underline drawing support.
- `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt` — pass combined analysis flags and protect title width.
- `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/WelcomeScreen.kt` — weighted/wrapping card copy.
- `android/app/src/main/kotlin/com/rhymeai/app/ui/components/AssistantPanel.kt` — remove low-contrast Graphite opacity stacking.
- `android/app/src/androidTest/kotlin/com/rhymeai/app/AppearancePersistenceInstrumentedTest.kt` — DataStore persistence.
- `android/app/src/androidTest/kotlin/com/rhymeai/app/AppearanceUiTest.kt` — selector persistence and screenshots.
- `android/app/src/androidTest/kotlin/com/rhymeai/app/NewFeatureUiTest.kt` — long-title and welcome layout checks.

---

### Task 1: iOS Analysis Preference State

**Files:**
- Create: `Writers Block/Writers Block/Support/AnalysisPresentationStyle.swift`
- Modify: `Writers Block/Writers Block/Writers_BlockApp.swift`
- Test: `Writers Block/Writers BlockTests/AnalysisPresentationStyleTests.swift`

**Interfaces:**
- Produces: `AnalysisPresentationStyle`, `InkUnderlinePattern`, `analysisInkPattern(for:)`, `analysisFontWeight(syllableCount:)`, `EnvironmentValues.analysisPresentationStyle`, and `EnvironmentValues.analysisPresentationBinding`.
- Consumed by: Tasks 3 and 5.

- [ ] **Step 1: Add failing state and encoding tests**

```swift
import SwiftUI
import Testing
@testable import Writers_Block

struct AnalysisPresentationStyleTests {
    @Test func rawValuesAndFallbackAreStable() {
        #expect(AnalysisPresentationStyle.color.rawValue == "color")
        #expect(AnalysisPresentationStyle.inkMarks.rawValue == "inkMarks")
        #expect(AnalysisPresentationStyle.storageKey == "analysisPresentationStyle")
        #expect(AnalysisPresentationStyle.resolve(nil) == .color)
        #expect(AnalysisPresentationStyle.resolve("unknown") == .color)
    }

    @Test func rhymePatternsAreStableAndUseAllFourPatterns() {
        let keys = ["EY1", "AY1", "OW1", "IY1", "ER1", "EH1", "AE1", "UW1"]
        let first = keys.map(analysisInkPattern)
        #expect(first == keys.map(analysisInkPattern))
        #expect(Set(first) == Set(InkUnderlinePattern.allCases))
    }

    @Test func syllableWeightsUseFourProgressiveBuckets() {
        #expect(analysisFontWeight(syllableCount: 1) == .regular)
        #expect(analysisFontWeight(syllableCount: 2) == .medium)
        #expect(analysisFontWeight(syllableCount: 3) == .semibold)
        #expect(analysisFontWeight(syllableCount: 4) == .bold)
        #expect(analysisFontWeight(syllableCount: 8) == .bold)
    }
}
```

- [ ] **Step 2: Run the tests and confirm the missing-type failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" \
  -scheme "Writers Block" \
  -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6' \
  -only-testing:'Writers BlockTests/AnalysisPresentationStyleTests'
```

Expected: FAIL because `AnalysisPresentationStyle` and encoding helpers do not exist.

- [ ] **Step 3: Implement the enum, helpers, and environment bindings**

Create the file with this public surface:

```swift
import SwiftUI

enum AnalysisPresentationStyle: String, CaseIterable, Hashable, Identifiable {
    case color
    case inkMarks

    static let storageKey = "analysisPresentationStyle"
    var id: String { rawValue }
    var displayName: String { self == .color ? "Color" : "Ink Marks" }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .color
    }
}

enum InkUnderlinePattern: Int, CaseIterable, Hashable {
    case solid, dashed, dotted, dashDot
}

func analysisInkPattern(for familyKey: String) -> InkUnderlinePattern {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in familyKey.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return InkUnderlinePattern(rawValue: Int(hash % 4)) ?? .solid
}

func analysisFontWeight(syllableCount: Int) -> Font.Weight {
    switch syllableCount {
    case ...1: .regular
    case 2: .medium
    case 3: .semibold
    default: .bold
    }
}

private struct AnalysisPresentationEnvironmentKey: EnvironmentKey {
    static let defaultValue: AnalysisPresentationStyle = .color
}

private struct AnalysisPresentationBindingEnvironmentKey: EnvironmentKey {
    static let defaultValue: Binding<AnalysisPresentationStyle> = .constant(.color)
}

extension EnvironmentValues {
    var analysisPresentationStyle: AnalysisPresentationStyle {
        get { self[AnalysisPresentationEnvironmentKey.self] }
        set { self[AnalysisPresentationEnvironmentKey.self] = newValue }
    }

    var analysisPresentationBinding: Binding<AnalysisPresentationStyle> {
        get { self[AnalysisPresentationBindingEnvironmentKey.self] }
        set { self[AnalysisPresentationBindingEnvironmentKey.self] = newValue }
    }
}
```

In `Writers_BlockApp`, add a second `@AppStorage`, resolved value/binding, and root environments:

```swift
@AppStorage(AnalysisPresentationStyle.storageKey)
private var analysisPresentationRawValue = AnalysisPresentationStyle.color.rawValue

private var analysisPresentation: AnalysisPresentationStyle {
    AnalysisPresentationStyle.resolve(analysisPresentationRawValue)
}

private var analysisPresentationBinding: Binding<AnalysisPresentationStyle> {
    Binding(
        get: { analysisPresentation },
        set: { analysisPresentationRawValue = $0.rawValue }
    )
}
```

```swift
.environment(\.analysisPresentationStyle, analysisPresentation)
.environment(\.analysisPresentationBinding, analysisPresentationBinding)
```

- [ ] **Step 4: Run the focused tests and diff check**

Run the Step 2 command again. Expected: all `AnalysisPresentationStyleTests` PASS.

Run:

```bash
git diff --check -- \
  "Writers Block/Writers Block/Support/AnalysisPresentationStyle.swift" \
  "Writers Block/Writers Block/Writers_BlockApp.swift" \
  "Writers Block/Writers BlockTests/AnalysisPresentationStyleTests.swift"
```

Expected: no output.

---

### Task 2: Android Analysis Preference State

**Files:**
- Create: `android/app/src/main/kotlin/com/rhymeai/app/data/model/AnalysisPresentation.kt`
- Create: `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/AnalysisPresentation.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/data/repository/ProjectRepository.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/MainViewModel.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/Theme.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/MainActivity.kt`
- Test: `android/app/src/test/kotlin/com/rhymeai/app/data/model/AnalysisPresentationTest.kt`
- Test: `android/app/src/test/kotlin/com/rhymeai/app/ui/theme/AnalysisInkMarksTest.kt`
- Test: `android/app/src/androidTest/kotlin/com/rhymeai/app/AppearancePersistenceInstrumentedTest.kt`

**Interfaces:**
- Produces: `AnalysisPresentation`, `InkUnderlinePattern`, `analysisInkPattern(String)`, `analysisFontWeight(Int)`, and `LocalAnalysisPresentation`.
- Consumed by: Tasks 4 and 6.

- [ ] **Step 1: Add failing enum/helper tests**

```kotlin
package com.rhymeai.app.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

class AnalysisPresentationTest {
    @Test fun `storage values and fallback remain stable`() {
        assertEquals("color", AnalysisPresentation.COLOR.storageValue)
        assertEquals("ink_marks", AnalysisPresentation.INK_MARKS.storageValue)
        assertEquals(AnalysisPresentation.COLOR, AnalysisPresentation.fromStorage(null))
        assertEquals(AnalysisPresentation.COLOR, AnalysisPresentation.fromStorage("unknown"))
    }
}
```

```kotlin
package com.rhymeai.app.ui.theme

import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Test

class AnalysisInkMarksTest {
    @Test fun `rhyme pattern mapping is deterministic`() {
        val keys = listOf("EY1", "AY1", "OW1", "IY1", "ER1", "EH1", "AE1", "UW1")
        assertEquals(keys.map(::analysisInkPattern), keys.map(::analysisInkPattern))
        assertEquals(InkUnderlinePattern.entries.toSet(), keys.map(::analysisInkPattern).toSet())
    }

    @Test fun `syllable weight uses four buckets`() {
        assertEquals(FontWeight.Normal, analysisFontWeight(1))
        assertEquals(FontWeight.Medium, analysisFontWeight(2))
        assertEquals(FontWeight.SemiBold, analysisFontWeight(3))
        assertEquals(FontWeight.Bold, analysisFontWeight(4))
        assertEquals(FontWeight.Bold, analysisFontWeight(8))
    }
}
```

- [ ] **Step 2: Run the tests and confirm missing-type failures**

Run:

```bash
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
./gradlew :app:testDebugUnitTest \
  --tests com.rhymeai.app.data.model.AnalysisPresentationTest \
  --tests com.rhymeai.app.ui.theme.AnalysisInkMarksTest
```

Expected: FAIL because the enum and helpers do not exist.

- [ ] **Step 3: Implement enum and deterministic helpers**

```kotlin
package com.rhymeai.app.data.model

enum class AnalysisPresentation(val storageValue: String, val displayName: String) {
    COLOR("color", "Color"),
    INK_MARKS("ink_marks", "Ink Marks");

    companion object {
        fun fromStorage(value: String?): AnalysisPresentation =
            entries.firstOrNull { it.storageValue == value } ?: COLOR
    }
}
```

```kotlin
package com.rhymeai.app.ui.theme

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.font.FontWeight
import com.rhymeai.app.data.model.AnalysisPresentation

enum class InkUnderlinePattern { SOLID, DASHED, DOTTED, DASH_DOT }

fun analysisInkPattern(familyKey: String): InkUnderlinePattern {
    var hash = -3750763034362895579L
    familyKey.encodeToByteArray().forEach { byte ->
        hash = hash xor (byte.toLong() and 0xff)
        hash *= 1099511628211L
    }
    return InkUnderlinePattern.entries[(hash.toULong() % 4u).toInt()]
}

fun analysisFontWeight(syllableCount: Int): FontWeight = when (syllableCount) {
    0, 1 -> FontWeight.Normal
    2 -> FontWeight.Medium
    3 -> FontWeight.SemiBold
    else -> FontWeight.Bold
}

val LocalAnalysisPresentation = staticCompositionLocalOf { AnalysisPresentation.COLOR }
```

- [ ] **Step 4: Add DataStore and ViewModel state**

In `ProjectRepository`:

```kotlin
private val ANALYSIS_PRESENTATION_KEY = stringPreferencesKey("analysis_presentation")

val analysisPresentationFlow: Flow<AnalysisPresentation> = context.dataStore.data.map { prefs ->
    AnalysisPresentation.fromStorage(prefs[ANALYSIS_PRESENTATION_KEY])
}

suspend fun saveAnalysisPresentation(value: AnalysisPresentation) {
    context.dataStore.edit { prefs ->
        prefs[ANALYSIS_PRESENTATION_KEY] = value.storageValue
    }
}
```

In `MainViewModel`, add state, load it next to appearance, and persist immediately:

```kotlin
private var _analysisPresentation by mutableStateOf(AnalysisPresentation.COLOR)
val analysisPresentation: AnalysisPresentation get() = _analysisPresentation
```

```kotlin
_appAppearance = runCatching { repo.appearanceFlow.first() }
    .getOrDefault(AppAppearance.INK)
_analysisPresentation = runCatching { repo.analysisPresentationFlow.first() }
    .getOrDefault(AnalysisPresentation.COLOR)
appearanceLoaded = true
```

Replace the existing appearance-only load with this three-line block so the splash gate does not reveal the default analysis style before the stored value is loaded.

```kotlin
fun setAnalysisPresentation(value: AnalysisPresentation) {
    _analysisPresentation = value
    viewModelScope.launch {
        try {
            repo.saveAnalysisPresentation(value)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            errorMessage = error.message ?: "Failed to save analysis style"
        }
    }
}
```

- [ ] **Step 5: Publish state at the root**

Change `RhymeAITheme` to accept and provide the value:

```kotlin
@Composable
fun RhymeAITheme(
    appearance: AppAppearance = AppAppearance.INK,
    analysisPresentation: AnalysisPresentation = AnalysisPresentation.COLOR,
    content: @Composable () -> Unit
) {
    CompositionLocalProvider(
        LocalAppAppearance provides appearance,
        LocalAnalysisPresentation provides analysisPresentation
    ) {
        MaterialTheme(
            colorScheme = colorSchemeFor(appearance),
            typography = RhymeTypography,
            shapes = RhymeShapes
        ) {
            ProvideAccessibleAnimations(content = content)
        }
    }
}
```

At the `MainActivity` call site:

```kotlin
RhymeAITheme(
    appearance = viewModel.appAppearance,
    analysisPresentation = viewModel.analysisPresentation
) {
```

- [ ] **Step 6: Add instrumented persistence coverage**

Extend `AppearancePersistenceInstrumentedTest`:

```kotlin
@Test fun analysisPresentationPersistsAndUnknownFallsBackToColor() = runBlocking {
    AnalysisPresentation.entries.forEach { value ->
        repo.saveAnalysisPresentation(value)
        assertEquals(value, repo.analysisPresentationFlow.first())
    }
}
```

- [ ] **Step 7: Run focused tests**

Run the Step 2 command again, then:

```bash
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class='com.rhymeai.app.AppearancePersistenceInstrumentedTest'
```

Expected: unit and persistence tests PASS.

---

### Task 3: iOS Ink Marks Rendering

**Files:**
- Modify: `Writers Block/Writers Block/Components/RhymeHighlightedText.swift`
- Modify: `Writers Block/Writers Block/Components/SyllableColoredText.swift`
- Modify: `Writers Block/Writers Block/Views/EditorView.swift`
- Test: `Writers Block/Writers BlockTests/AnalysisPresentationStyleTests.swift`

**Interfaces:**
- Consumes: Task 1 environment state and helpers.
- Produces: presentation-aware attributed analysis without changing call-site data flow.

- [ ] **Step 1: Add failing line-style tests**

Add to `AnalysisPresentationStyleTests`:

```swift
@Test func everyInkPatternMapsToADistinctLineStyle() {
    let styles = InkUnderlinePattern.allCases.map(\.lineStyle)
    #expect(Set(styles.map(String.init(describing:))).count == 4)
}
```

Run the Task 1 test command. Expected: FAIL because `lineStyle` is missing.

- [ ] **Step 2: Add native line-style mapping**

```swift
extension InkUnderlinePattern {
    var lineStyle: Text.LineStyle {
        switch self {
        case .solid: Text.LineStyle(pattern: .solid)
        case .dashed: Text.LineStyle(pattern: .dash)
        case .dotted: Text.LineStyle(pattern: .dot)
        case .dashDot: Text.LineStyle(pattern: .dashDot)
        }
    }
}
```

- [ ] **Step 3: Make rhyme highlighting presentation-aware**

Add the environment value:

```swift
@Environment(\.analysisPresentationStyle) private var analysisPresentation
```

Remove `.equatable()` from the `RhymeHighlightedText` call in `EditorView`. The current custom equality excludes environment state, so retaining that wrapper could suppress an immediate Color/Ink Marks redraw.

Replace the rhyme segment styling branch with:

```swift
if enabled, let familyKey = familyKeyPerToken[i] {
    switch analysisPresentation {
    case .color:
        seg.foregroundColor = colorFor(key: familyKey)
        seg.font = .body.weight(.semibold)
    case .inkMarks:
        seg.foregroundColor = appearance.palette.primaryInk
        seg.underlineStyle = analysisInkPattern(for: familyKey).lineStyle
        seg.font = .body.weight(
            syllablesEnabled ? analysisFontWeight(syllableCount: count) : .semibold
        )
    }
} else if analysisPresentation == .inkMarks, syllablesEnabled {
    seg.foregroundColor = appearance.palette.primaryInk
    seg.font = .body.weight(analysisFontWeight(syllableCount: count))
} else {
    seg.foregroundColor = .primary
    if syllablesEnabled {
        seg.underlineStyle = Text.LineStyle(
            pattern: .solid,
            color: syllableColor(for: count)
        )
    }
}
```

When both analyses are active in Ink Marks, do not overwrite the rhyme underline with the syllable color underline.

- [ ] **Step 4: Make standalone syllable rendering presentation-aware**

In `SyllableColoredText`, add the environment value and use authored ink/weight in Ink Marks:

```swift
if analysisPresentation == .inkMarks {
    segment.foregroundColor = appearance.palette.primaryInk
    segment.font = .body.weight(analysisFontWeight(syllableCount: count))
} else {
    segment.foregroundColor = .primary
    segment.underlineStyle = Text.LineStyle(
        pattern: .solid,
        color: syllableColor(for: count)
    )
}
```

- [ ] **Step 5: Run tests and build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" \
  -scheme "Writers Block" \
  -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6' \
  -only-testing:'Writers BlockTests/AnalysisPresentationStyleTests' \
  -only-testing:'Writers BlockTests/AppAppearanceTests'
```

Expected: tests PASS and Swift source compiles.

---

### Task 4: Android Ink Marks Rendering

**Files:**
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/RhymeHighlightedText.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SyllableColoredText.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt`
- Test: `android/app/src/test/kotlin/com/rhymeai/app/ui/components/RhymeHighlightedTextTest.kt`
- Test: `android/app/src/test/kotlin/com/rhymeai/app/ui/theme/AnalysisInkMarksTest.kt`

**Interfaces:**
- Consumes: Task 2 composition local and helpers.
- Produces: unified analysis text with patterned rhyme spans and syllable weight.

- [ ] **Step 1: Add failing pure span tests**

Add tests that call a new pure builder:

```kotlin
@Test fun `ink marks use authored ink and syllable weights`() {
    val result = buildAnalysisText(
        text = "light night tomorrow",
        baseTextColor = Color.Black,
        rhymePalette = listOf(Color.Red, Color.Blue),
        isDark = false,
        presentation = AnalysisPresentation.INK_MARKS,
        rhymeEnabled = true,
        syllablesEnabled = true
    )

    assertTrue(result.rhymeSpans.isNotEmpty())
    assertTrue(result.rhymeSpans.all { it.color == Color.Black })
    assertEquals(FontWeight.Bold, result.wordWeights.last().weight)
}
```

Run:

```bash
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
./gradlew :app:testDebugUnitTest \
  --tests com.rhymeai.app.ui.components.RhymeHighlightedTextTest \
  --tests com.rhymeai.app.ui.theme.AnalysisInkMarksTest
```

Expected: FAIL because `buildAnalysisText` and result span types are missing.

- [ ] **Step 2: Add pure analysis result types**

```kotlin
@Immutable
data class RhymeUnderlineSpan(
    val start: Int,
    val endExclusive: Int,
    val color: Color,
    val pattern: InkUnderlinePattern
)

@Immutable
data class AnalysisWordWeight(
    val start: Int,
    val endExclusive: Int,
    val weight: FontWeight
)

@Immutable
data class AnalysisTextResult(
    val text: AnnotatedString,
    val rhymeSpans: List<RhymeUnderlineSpan>,
    val wordWeights: List<AnalysisWordWeight>
)
```

Implement the pure builder with the existing tokenizer and phonetics service:

```kotlin
internal fun buildAnalysisText(
    text: String,
    baseTextColor: Color,
    rhymePalette: List<Color>,
    isDark: Boolean,
    presentation: AnalysisPresentation,
    rhymeEnabled: Boolean,
    syllablesEnabled: Boolean
): AnalysisTextResult {
    val tokens = wordPattern.findAll(text)
        .map { Token(it.value, it.range.first, it.range.last + 1) }
        .toList()
    val keysPerToken = tokens.map { RhymePhonetics.rhymeKeys(it.text, maxDepth = 2) }
    val occurrences = mutableMapOf<String, Int>()
    keysPerToken.flatten().forEach { key -> occurrences[key] = (occurrences[key] ?: 0) + 1 }
    val familyKeys = keysPerToken.map { keys -> keys.lastOrNull { (occurrences[it] ?: 0) >= 2 } }
    val familyColors = assignRhymeFamilyColors(familyKeys, rhymePalette)
    val rhymeSpans = mutableListOf<RhymeUnderlineSpan>()
    val weights = mutableListOf<AnalysisWordWeight>()

    val annotated = buildAnnotatedString {
        var cursor = 0
        tokens.forEachIndexed { index, token ->
            if (token.start > cursor) {
                withStyle(SpanStyle(color = baseTextColor)) {
                    append(text.substring(cursor, token.start))
                }
            }

            val count = SyllableCounter.count(token.text)
            val familyKey = familyKeys[index]
            val style = when (presentation) {
                AnalysisPresentation.COLOR -> when {
                    rhymeEnabled && familyKey != null -> SpanStyle(
                        color = familyColors.getValue(familyKey),
                        fontWeight = FontWeight.SemiBold
                    )
                    !rhymeEnabled && syllablesEnabled -> SpanStyle(
                        color = syllableColor(count, isDark),
                        fontWeight = FontWeight.SemiBold
                    )
                    else -> SpanStyle(color = baseTextColor)
                }
                AnalysisPresentation.INK_MARKS -> {
                    val weight = if (syllablesEnabled) analysisFontWeight(count) else FontWeight.SemiBold
                    if (syllablesEnabled) {
                        weights += AnalysisWordWeight(token.start, token.end, weight)
                    }
                    if (rhymeEnabled && familyKey != null) {
                        rhymeSpans += RhymeUnderlineSpan(
                            start = token.start,
                            endExclusive = token.end,
                            color = baseTextColor,
                            pattern = analysisInkPattern(familyKey)
                        )
                    }
                    SpanStyle(color = baseTextColor, fontWeight = weight)
                }
            }
            withStyle(style) { append(token.text) }
            cursor = token.end
        }
        if (cursor < text.length) {
            withStyle(SpanStyle(color = baseTextColor)) { append(text.substring(cursor)) }
        }
    }

    return AnalysisTextResult(annotated, rhymeSpans, weights)
}
```

- [ ] **Step 3: Add patterned line drawing**

Extend the current underline draw helper with pattern-specific `PathEffect`:

```kotlin
private fun InkUnderlinePattern.pathEffect(strokeWidth: Float): PathEffect? = when (this) {
    InkUnderlinePattern.SOLID -> null
    InkUnderlinePattern.DASHED -> PathEffect.dashPathEffect(floatArrayOf(4 * strokeWidth, 3 * strokeWidth))
    InkUnderlinePattern.DOTTED -> PathEffect.dashPathEffect(floatArrayOf(strokeWidth, 2.5f * strokeWidth))
    InkUnderlinePattern.DASH_DOT -> PathEffect.dashPathEffect(
        floatArrayOf(4 * strokeWidth, 2 * strokeWidth, strokeWidth, 2 * strokeWidth)
    )
}
```

Pass the effect into `drawLine(pathEffect = pattern.pathEffect(strokeWidth))`, retaining the existing wrapped-line segmentation.

- [ ] **Step 4: Unify the Editor overlay call**

Change `RhymeHighlightedText` to accept both flags:

```kotlin
@Composable
fun RhymeHighlightedText(
    text: String,
    enabled: Boolean,
    syllablesEnabled: Boolean = false,
    modifier: Modifier = Modifier,
    style: TextStyle = TextStyle.Default
)
```

In `EditorScreen`, use it whenever either analysis is active:

```kotlin
RhymeHighlightedText(
    text = viewModel.lyrics,
    enabled = viewModel.isRhymeHighlightEnabled,
    syllablesEnabled = viewModel.isSyllableColoringEnabled,
    modifier = Modifier.fillMaxWidth(),
    style = lyricsStyle
)
```

For `SyllableWordColoredText`, replace the current unconditional color span with:

```kotlin
val presentation = LocalAnalysisPresentation.current
val annotated = remember(text, baseTextColor, isDark, presentation) {
    buildSyllableWordAnnotatedString(
        text = text,
        baseTextColor = baseTextColor,
        isDark = isDark,
        presentation = presentation
    )
}
```

The pure builder applies `syllableColor(...)` plus `SemiBold` in Color mode and `baseTextColor` plus `analysisFontWeight(count)` in Ink Marks.

- [ ] **Step 5: Run focused tests and compile**

Run the Step 1 command, then:

```bash
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
./gradlew :app:compileDebugKotlin
```

Expected: tests and Kotlin compile PASS.

---

### Task 5: iOS Analysis Settings UI

**Files:**
- Create: `Writers Block/Writers Block/Views/AnalysisStyleSettingsSection.swift`
- Modify: `Writers Block/Writers Block/Views/SettingsView.swift`
- Modify: `Writers Block/Writers BlockUITests/AppAppearanceUITests.swift`

**Interfaces:**
- Consumes: Task 1 binding and Task 3 rendering behavior.
- Produces: `analysisStylePicker` accessibility identifier and preview legend.

- [ ] **Step 1: Add failing UI assertions**

Add to `AppAppearanceUITests`:

```swift
@MainActor
func testAnalysisStyleAppliesImmediatelyAndPersists() throws {
    let app = appearanceTestApp()
    app.launch()
    openSettings(in: app)

    let picker = app.segmentedControls["analysisStylePicker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    picker.buttons["Color"].tap()
    XCTAssertTrue(picker.buttons["Color"].isSelected)
    picker.buttons["Ink Marks"].tap()
    XCTAssertTrue(picker.buttons["Ink Marks"].isSelected)
    XCTAssertTrue(app.staticTexts["Solid, dashed, dotted, and dash-dot lines identify rhyme families."].exists)

    app.terminate()
    app.launch()
    openSettings(in: app)
    XCTAssertTrue(app.segmentedControls["analysisStylePicker"].buttons["Ink Marks"].isSelected)
}
```

Run this single test. Expected: FAIL because the picker is absent.

- [ ] **Step 2: Implement the Settings component**

Create a native selector with an authored preview:

```swift
import SwiftUI

struct AnalysisStyleSettingsSection: View {
    @Environment(\.analysisPresentationBinding) private var presentation
    @Environment(\.appAppearanceStyle) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Label("Analysis Style", systemImage: "textformat.abc.dottedunderline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.palette.secondaryInk)
                .textCase(.uppercase)

            Picker("Analysis Style", selection: presentation) {
                ForEach(AnalysisPresentationStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("analysisStylePicker")

            AnalysisStylePreview(style: presentation.wrappedValue)

            if presentation.wrappedValue == .inkMarks {
                Text("Solid, dashed, dotted, and dash-dot lines identify rhyme families.")
                Text("Heavier words contain more syllables.")
            } else {
                Text("Color identifies rhyme families and syllable counts.")
            }
        }
        .foregroundStyle(appearance.palette.secondaryInk)
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl)
    }
}
```

`AnalysisStylePreview` must render real `RhymeHighlightedText` with a fixed two-line sample; do not draw fake swatches that bypass the production renderer.

- [ ] **Step 3: Place it after Appearance**

In `SettingsView`:

```swift
AppearanceSettingsSection()
AnalysisStyleSettingsSection()
```

- [ ] **Step 4: Run the UI test**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" \
  -scheme "Writers Block" \
  -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6' \
  -only-testing:'Writers BlockUITests/AppAppearanceUITests/testAnalysisStyleAppliesImmediatelyAndPersists'
```

Expected: PASS.

---

### Task 6: Android Analysis Settings UI

**Files:**
- Create: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/AnalysisStyleSelector.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SettingsDialog.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/MainActivity.kt`
- Modify: `android/app/src/androidTest/kotlin/com/rhymeai/app/AppearanceUiTest.kt`

**Interfaces:**
- Consumes: Task 2 state/callback and Task 4 renderer.
- Produces: `analysisStyleSelector` test tag and preview legend.

- [ ] **Step 1: Add a failing persistence UI flow**

Add to `AppearanceUiTest`:

```kotlin
@Test fun analysisStyleAppliesImmediatelyAndPersistsAfterRelaunch() {
    openEditor()
    openAppearanceSettings()
    composeRule.onNodeWithTag("analysisStyleSelector").assertExists()
    composeRule.onNode(hasText("Color") and isSelected()).assertExists()
    composeRule.onNode(hasText("Ink Marks") and hasClickAction()).performClick()
    composeRule.onNode(hasText("Ink Marks") and isSelected()).assertExists()
    composeRule.onNodeWithText("Heavier words contain more syllables.").assertExists()

    runBlocking {
        withTimeout(5_000) {
            repository.analysisPresentationFlow.first { it == AnalysisPresentation.INK_MARKS }
        }
    }

    scenario?.close()
    scenario = ActivityScenario.launch(MainActivity::class.java)
    openEditor()
    openAppearanceSettings()
    composeRule.onNode(hasText("Ink Marks") and isSelected()).assertExists()
}
```

Also add `repository.saveAnalysisPresentation(AnalysisPresentation.COLOR)` to both `setUp` and `tearDown` so this persistence test is isolated from previous runs.

Run the single test. Expected: FAIL because the selector is absent.

- [ ] **Step 2: Add Settings parameters and root callback**

Extend `SettingsDialog`:

```kotlin
currentAnalysisPresentation: AnalysisPresentation,
onAnalysisPresentationChange: (AnalysisPresentation) -> Unit,
```

At `MainActivity`:

```kotlin
currentAnalysisPresentation = viewModel.analysisPresentation,
onAnalysisPresentationChange = viewModel::setAnalysisPresentation,
```

- [ ] **Step 3: Implement the selector using production rendering**

```kotlin
@Composable
fun AnalysisStyleSelector(
    current: AnalysisPresentation,
    onChange: (AnalysisPresentation) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
        Text("Analysis Style", style = MaterialTheme.typography.labelMedium)
        SlidingSegmentedControl(
            labels = AnalysisPresentation.entries.map { it.displayName },
            selectedIndex = AnalysisPresentation.entries.indexOf(current),
            onSelect = { onChange(AnalysisPresentation.entries[it]) },
            modifier = Modifier.fillMaxWidth().testTag("analysisStyleSelector")
        )
        CompositionLocalProvider(LocalAnalysisPresentation provides current) {
            RhymeHighlightedText(
                text = "light in the night\ntomorrow finds a brighter road",
                enabled = true,
                syllablesEnabled = true,
                style = MaterialTheme.typography.bodyMedium
            )
        }
        Text(
            if (current == AnalysisPresentation.INK_MARKS)
                "Heavier words contain more syllables."
            else
                "Color identifies rhyme families and syllable counts.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall
        )
    }
}
```

Place it immediately after `AppearanceSelector`, before Provider.

- [ ] **Step 4: Run the UI flow**

Run:

```bash
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class='com.rhymeai.app.AppearanceUiTest#analysisStyleAppliesImmediatelyAndPersistsAfterRelaunch'
```

Expected: PASS.

---

### Task 7: iOS Compact Chrome, Welcome Layout, and Graphite Contrast

**Files:**
- Modify: `Writers Block/Writers Block/Views/EditorView.swift`
- Modify: `Writers Block/Writers Block/Views/WelcomeView.swift`
- Modify: `Writers Block/Writers Block/Views/AssistantPanelView.swift`
- Modify: `Writers Block/Writers Block/Support/UITestFlags.swift`
- Modify: `Writers Block/Writers Block/ViewModels/EditorViewModel.swift`
- Modify: `Writers Block/Writers BlockUITests/Writers_BlockUITests.swift`

**Interfaces:**
- Produces: `editorCompactStats` accessibility identifier and stable welcome-card geometry.

- [ ] **Step 1: Add failing long-title and welcome tests**

```swift
@MainActor
func testCompactTopBarPreservesLongTitleAndActions() throws {
    try requirePhone()
    let app = isolatedUITestApp(arguments: ["--ui-test-seed-long-title-song"])
    app.launch()
    let title = app.staticTexts["editorTopBarTitle"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(title.frame.width, 100)
    XCTAssertTrue(app.buttons["Share"].isHittable)
    XCTAssertTrue(app.buttons["Settings"].isHittable)
    XCTAssertTrue(app.staticTexts["editorCompactStats"].exists)
}

@MainActor
func testWelcomeCardsGrowAtAccessibilityTextSize() throws {
    try requirePhone()
    let app = isolatedUITestApp(arguments: ["--ui-test-accessibility-text-size"])
    app.launch()
    for label in ["New Song", "Load Song", "Song Templates"] {
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
    }
}
```

Add `--ui-test-seed-long-title-song` in `UITestFlags` with a title longer than 45 characters. Run both tests. Expected: at least the compact-stats assertion fails.

- [ ] **Step 2: Implement compact counters and authored top-bar colors**

Give `titleAndSaveStatus` `.layoutPriority(2)` and replace `wordAndSyllableCounts` with:

```swift
private var wordAndSyllableCounts: some View {
    ViewThatFits(in: .horizontal) {
        VStack(alignment: .trailing, spacing: EditorViewConstants.TopBar.counterSpacing) {
            Text("\(viewModel.wordCount) words")
            Text("\(viewModel.syllableCount) syllables")
        }
        .fixedSize(horizontal: true, vertical: false)

        Text("\(viewModel.wordCount)w · \(viewModel.syllableCount)s")
            .accessibilityIdentifier("editorCompactStats")
            .accessibilityLabel("\(viewModel.wordCount) words, \(viewModel.syllableCount) syllables")
    }
    .font(.caption)
    .foregroundStyle(appearance.palette.secondaryInk)
}
```

Replace app-owned `.secondary` and `.secondary.opacity(...)` in the top bar with `appearance.palette.secondaryInk`; keep disabled-state opacity only where the control is truly disabled.

- [ ] **Step 3: Stabilize Welcome cards**

In the horizontal phone card branch:

```swift
VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
    Text(title)
        .font(.headline)
        .foregroundStyle(appearance.palette.primaryInk)
        .fixedSize(horizontal: false, vertical: true)
    Text(subtitle)
        .font(.caption)
        .foregroundStyle(appearance.palette.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
}
.frame(maxWidth: .infinity, alignment: .leading)
.layoutPriority(1)
```

Apply the same vertical fixed sizing to iPad card text, use authored secondary ink for subtitle/chevron/subtitle copy, and retain existing vertical arrangement at accessibility sizes.

- [ ] **Step 4: Correct Graphite Assistant emphasis**

In `AssistantPanelView`, replace app-owned `.secondary.opacity(0.5)`/`.secondary` text with either:

```swift
.foregroundStyle(appearance.palette.secondaryInk)
```

or, for placeholders:

```swift
.foregroundStyle(appearance.palette.placeholder)
```

Do not change semantic error/success/recording colors.

- [ ] **Step 5: Run focused UI tests and build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" \
  -scheme "Writers Block" \
  -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6' \
  -only-testing:'Writers BlockUITests/Writers_BlockUITests/testCompactTopBarPreservesLongTitleAndActions' \
  -only-testing:'Writers BlockUITests/Writers_BlockUITests/testWelcomeCardsGrowAtAccessibilityTextSize'
```

Expected: both tests PASS.

---

### Task 8: Android Compact Chrome, Welcome Layout, and Graphite Contrast

**Files:**
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/WelcomeScreen.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/AssistantPanel.kt`
- Modify: `android/app/src/main/res/values/strings.xml`
- Modify: `android/app/src/androidTest/kotlin/com/rhymeai/app/NewFeatureUiTest.kt`

**Interfaces:**
- Produces: `editorTopBarTitle`, `welcomeCardText`, and contrast-safe affected surfaces.

- [ ] **Step 1: Add failing geometry tests**

```kotlin
@Test fun longEditorTitleKeepsActionsReachable() {
    launchSeededEditor(title = "A Very Long Song Title That Still Needs Useful Context")
    val title = composeRule.onNodeWithTag("editorTopBarTitle").getUnclippedBoundsInRoot()
    assertTrue("Title needs at least 100dp", title.width.value >= 100f)
    composeRule.onNodeWithContentDescription("Share").assertIsDisplayed().assertHasClickAction()
    composeRule.onNodeWithContentDescription("Settings").assertIsDisplayed().assertHasClickAction()
}

@Test fun welcomeCardsRemainHittableAtLargeFontScale() {
    setFontScale(1.5f)
    relaunchActivity()
    listOf("New Song", "Load Song", "Song Templates").forEach { label ->
        composeRule.onNodeWithText(label).assertIsDisplayed()
    }
}
```

Run both tests. Expected: the long-title minimum-width assertion fails on current compact geometry.

- [ ] **Step 2: Protect title width**

In the `TopAppBar` title row, change the text to fill remaining title space and keep status fixed:

```kotlin
Text(
    text = viewModel.title.ifBlank { "Untitled Song" },
    style = MaterialTheme.typography.titleSmall,
    color = colorScheme.onSurfaceVariant,
    maxLines = 1,
    overflow = TextOverflow.Ellipsis,
    modifier = Modifier
        .weight(1f, fill = true)
        .testTag("editorTopBarTitle")
)
```

Retain 48dp `IconButton`s and do not hide Share or Settings.

- [ ] **Step 3: Stabilize Welcome copy**

Replace the unbounded card `Column` with:

```kotlin
Column(
    modifier = Modifier
        .weight(1f)
        .testTag("welcomeCardText"),
    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
) {
    Text(
        title,
        fontWeight = FontWeight.Medium,
        style = MaterialTheme.typography.titleMedium,
        color = colorScheme.onSurface
    )
    Text(
        subtitle,
        style = MaterialTheme.typography.bodySmall,
        color = colorScheme.onSurfaceVariant
    )
}
```

Do not add fixed card height or `maxLines`; let Material typography grow vertically.

- [ ] **Step 4: Correct Graphite Assistant emphasis**

Remove extra alpha from app-owned helper/placeholder text that already uses `onSurfaceVariant`; use `placeholderColorFor(LocalAppAppearance.current)` for placeholders. Keep alpha only for truly disabled controls.

- [ ] **Step 5: Run focused UI tests and compile**

Run:

```bash
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class='com.rhymeai.app.NewFeatureUiTest#longEditorTitleKeepsActionsReachable,com.rhymeai.app.NewFeatureUiTest#welcomeCardsRemainHittableAtLargeFontScale'
```

Then run `./gradlew :app:compileDebugKotlin`. Expected: focused UI tests and compile PASS.

---

### Task 9: Cross-Platform Regression and Visual Completion Gate

**Files:**
- Modify only if a current-build failure is traced to this polish scope.
- Evidence: `artifacts/focused-polish-2026-07-12/ios/`
- Evidence: `artifacts/focused-polish-2026-07-12/android/`

**Interfaces:**
- Consumes: Tasks 1-8 current build.
- Produces: twelve fresh screenshots, runtime logs, build/test evidence, and two independent PASS verdicts.

- [ ] **Step 1: Run Android static/unit/build gates**

```bash
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
./gradlew check lint assembleDebug
```

Expected: BUILD SUCCESSFUL. If unrelated connected tests remain red, report them separately; do not weaken them.

- [ ] **Step 2: Run focused Android device flows**

```bash
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class='com.rhymeai.app.AppearanceUiTest,com.rhymeai.app.AppearancePersistenceInstrumentedTest,com.rhymeai.app.NewFeatureUiTest'
```

Expected: all polish-focused tests pass. Preserve exact output for any unrelated existing failure.

- [ ] **Step 3: Run iOS unit/build gates**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild test -project "Writers Block/Writers Block.xcodeproj" \
  -scheme "Writers Block" \
  -destination 'platform=iOS Simulator,id=9421D79B-4889-41C8-A355-815D4C11FDF6' \
  -only-testing:'Writers BlockTests/AnalysisPresentationStyleTests' \
  -only-testing:'Writers BlockTests/AppAppearanceTests' \
  -only-testing:'Writers BlockTests/LyricsDynamicTypeTests'
```

Expected: selected unit suites PASS.

- [ ] **Step 4: Run iPhone and iPad UI gates**

Run `AppAppearanceUITests` and the new focused methods in `Writers_BlockUITests` on iPhone, then run the iPad-specific long-title/welcome state on simulator `2F653733-FB4C-4D15-9F4A-6D21EDAE09DF`. Expected: all focused UI tests PASS.

- [ ] **Step 5: Capture the complete twelve-state evidence set**

Create:

```text
artifacts/focused-polish-2026-07-12/ios/01-welcome-standard.png
artifacts/focused-polish-2026-07-12/ios/02-welcome-accessibility.png
artifacts/focused-polish-2026-07-12/ios/03-editor-long-title-color.png
artifacts/focused-polish-2026-07-12/ios/04-editor-long-title-ink-marks.png
artifacts/focused-polish-2026-07-12/ios/05-graphite-assistant.png
artifacts/focused-polish-2026-07-12/ios/06-ipad-welcome.png
artifacts/focused-polish-2026-07-12/ios/07-ipad-editor-ink-marks.png
artifacts/focused-polish-2026-07-12/android/08-welcome-standard.png
artifacts/focused-polish-2026-07-12/android/09-welcome-large-font.png
artifacts/focused-polish-2026-07-12/android/10-editor-long-title-color.png
artifacts/focused-polish-2026-07-12/android/11-editor-long-title-ink-marks.png
artifacts/focused-polish-2026-07-12/android/12-graphite-assistant.png
```

Use XCTest attachments/simctl for iOS and the Android emulator QA workflow for Android. Derive Android taps from UI-tree bounds, not screenshot coordinates. Every file must be newer than the last source edit.

- [ ] **Step 6: Manually inspect runtime behavior**

On each platform: switch Color → Ink Marks, enable rhyme and syllable analysis together, edit lyrics, verify no typing stall, switch Graphite, open Assistant, relaunch, and confirm Ink Marks remains selected. Save filtered app logs and verify there is no crash, `Publishing changes from within view updates`, or Compose snapshot exception.

- [ ] **Step 7: Dispatch both required read-only visual reviews**

Send all twelve paths and the current source/diff to two independent reviewers:

1. design-system and functional integrity;
2. visual fidelity, wrapping, contrast, and accessibility precision.

Each must return `PASS` with no blocking finding on the same current build. If either returns `REVISE` or `FAIL`, fix only the scoped finding, rebuild, recapture all affected states, and rerun both reviews.

- [ ] **Step 8: Final repository hygiene**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors, no debug journals, no temporary result bundles in the repository, and no unrelated user changes reverted. Do not commit or push.
