# Android Phi Rhythm and Writer's Marks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. This workspace prohibits subagent delegation unless the user explicitly requests it.

**Goal:** Rebalance the Android editor and Settings around a Fibonacci-derived visual rhythm, then add restrained title, save, and press character without changing app behavior.

**Architecture:** Add focused rhythm and typography tokens without changing the global spacing ladder. Recompose the existing editor from the same ViewModel state, moving lyric statistics into the writing column and keeping decorative motion local to `EditorScreen.kt`. Simplify Settings through existing Material components and the shared segmented control.

**Tech Stack:** Kotlin 2.3.20, Jetpack Compose Material 3, Compose UI testing, Gradle 9.0 wrapper, Android emulator.

## Global Constraints

- Use the Fibonacci-derived 8dp, 13dp, 21dp, 34dp, and 55dp rhythm on the focused Android surfaces.
- Preserve minimum 48dp touch targets, system font scaling, reduced motion, current semantics, and native Material behavior.
- Preserve Ink, Paper, and Graphite palettes and the right-side UnBlock-then-microphone order.
- Do not add ViewModel state, persistence, dependencies, color, font families, sound, haptics, or iOS changes.
- Work around all unrelated dirty-worktree changes. Do not commit or push because the user has not requested source publication.

---

### Task 1: Phi editor tokens and UnBlock geometry

**Files:**
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/DesignTokens.kt`
- Modify: `android/app/src/test/kotlin/com/rhymeai/app/ui/screens/UnBlockSizingTest.kt`

**Interfaces:**
- Produces: `DesignTokens.Rhythm`, focused editor typography tokens, and a 144dp default `unBlockExtendedWidth` consumed by later tasks.

- [ ] **Step 1: Update the sizing tests first**

Replace the two test bodies with:

```kotlin
@Test
fun normalWordmarkUsesPhiSquaredRestingWidth() {
    assertEquals(144.dp, unBlockButtonWidth(60.dp, 300.dp))
}

@Test
fun enlargedWordmarkExpandsWithoutExceedingAvailableWidth() {
    assertEquals(167.dp, unBlockButtonWidth(120.dp, 240.dp))
    assertEquals(160.dp, unBlockButtonWidth(120.dp, 160.dp))
}
```

- [ ] **Step 2: Run the test to confirm red**

Run from `android/`:

```bash
./gradlew :app:testDebugUnitTest --tests com.rhymeai.app.ui.screens.UnBlockSizingTest
```

Expected: FAIL because the current resting width is 150dp and the expanded result is 178dp.

- [ ] **Step 3: Add focused rhythm tokens and update editor geometry**

Add to `DesignTokens.kt`:

```kotlin
object Rhythm {
    val tight = 8.dp
    val related = 13.dp
    val standard = 21.dp
    val section = 34.dp
    val primary = 55.dp
}
```

Update `Editor`:

```kotlin
val horizontalPadding = Rhythm.standard
val lyricFontSize = 17.sp
val lyricLineHeight = 27.sp
val lyricMeasureLineHeight = 27.dp
val titleFontSize = 34.sp
val titleLineHeight = 42.sp
val metadataFontSize = 13.sp
val metadataLineHeight = 16.sp
```

Update `EditorChrome`:

```kotlin
val fabSize = Rhythm.primary
val micRecordingRestWidth = fabSize
val unBlockExtendedWidth = 144.dp
val unBlockHorizontalPadding = Rhythm.standard
```

- [ ] **Step 4: Run the sizing test to confirm green**

Run the Step 2 command again. Expected: 2 tests PASS.

---

### Task 2: Rebalanced editor hierarchy and metadata placement

**Files:**
- Modify: `android/app/src/androidTest/kotlin/com/rhymeai/app/NewFeatureUiTest.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt`

**Interfaces:**
- Consumes: `DesignTokens.Rhythm` and editor typography from Task 1.
- Produces: `editorStats` below `songTitleEditor`, with the existing `LyricStats` as its only state input.

- [ ] **Step 1: Add the failing layout test**

Add to `NewFeatureUiTest`:

```kotlin
@Test
fun lyricStatsSitBelowTheEditableTitle() {
    composeRule.onNodeWithText("New Song").performClick()

    val topBarTitle = composeRule.onNodeWithTag("editorTopBarTitle")
        .assertIsDisplayed()
        .getUnclippedBoundsInRoot()
    val title = composeRule.onNodeWithTag("songTitleEditor")
        .assertIsDisplayed()
        .getUnclippedBoundsInRoot()
    val stats = composeRule.onNodeWithTag("editorStats")
        .assertTextEquals("0 words · 0 syllables")
        .getUnclippedBoundsInRoot()

    assertTrue("Stats must leave the top-bar action cluster", stats.top.value > topBarTitle.bottom.value)
    assertTrue("Stats must follow the editable title", stats.top.value >= title.bottom.value)
}
```

- [ ] **Step 2: Run the new instrumented test to confirm red**

Run from `android/` with an emulator attached:

```bash
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rhymeai.app.NewFeatureUiTest#lyricStatsSitBelowTheEditableTitle
```

Expected: FAIL because `editorStats` does not exist.

- [ ] **Step 3: Remove statistics from `TopAppBar.actions`**

Delete the `Column` that renders separate word and syllable labels. Keep export and settings `IconButton`s unchanged.

- [ ] **Step 4: Recompose the writing-column header**

Track title focus next to the existing editor state:

```kotlin
var titleFocused by remember { mutableStateOf(false) }
```

Use the focused title typography and tag:

```kotlin
val titleStyle = MaterialTheme.typography.headlineLarge.copy(
    color = colorScheme.onBackground,
    fontSize = DesignTokens.Editor.titleFontSize,
    lineHeight = DesignTokens.Editor.titleLineHeight
)
```

Apply `.onFocusChanged { titleFocused = it.isFocused }` to `songTitleEditor`, use `titleStyle` for both text and placeholder, then add beneath it:

```kotlin
Spacer(Modifier.height(DesignTokens.Rhythm.tight))
Text(
    text = "${lyricStats.wordCount} words · ${lyricStats.syllableCount} syllables",
    color = colorScheme.onSurfaceVariant,
    fontSize = DesignTokens.Editor.metadataFontSize,
    lineHeight = DesignTokens.Editor.metadataLineHeight,
    modifier = Modifier.testTag("editorStats")
)
Spacer(Modifier.height(DesignTokens.Rhythm.standard))
```

Replace the old title-to-lyrics `Spacing.xl` spacer. Preserve title height measurement, scrolling, caret safety, and lyric overlays.

- [ ] **Step 5: Run the new layout test and existing right-edge test**

Run the two tests serially:

```bash
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rhymeai.app.NewFeatureUiTest#lyricStatsSitBelowTheEditableTitle
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rhymeai.app.NewFeatureUiTest#editorActionsStayGroupedAtTheRightEdge
```

Expected: both commands PASS after updating the right-inset expectation from `Spacing.xl` to `Rhythm.standard`.

---

### Task 3: Writer's marks and action press response

**Files:**
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt`

**Interfaces:**
- Consumes: local `titleFocused`, `SaveStatus`, `LocalAnimationsEnabled`, and each existing `MutableInteractionSource`.
- Produces: decorative `TitleFocusMark`, `SavedFlourish`, and `rememberPressScale` helpers with no business-state output.

- [ ] **Step 1: Add deterministic decorative helpers**

Add private composables at the bottom of `EditorScreen.kt`:

```kotlin
@Composable
private fun TitleFocusMark(focused: Boolean, modifier: Modifier = Modifier) {
    val animationsEnabled = LocalAnimationsEnabled.current
    val progress by animateFloatAsState(
        targetValue = if (focused) 1f else 0f,
        animationSpec = if (animationsEnabled) {
            tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)
        } else {
            snap()
        },
        label = "titleFocusMark"
    )
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    Canvas(modifier) {
        clipRect(right = size.width * progress) {
            val path = Path().apply {
                moveTo(0f, size.height * 0.55f)
                lineTo(size.width * 0.34f, size.height * 0.28f)
                lineTo(size.width * 0.67f, size.height * 0.68f)
                lineTo(size.width, size.height * 0.38f)
            }
            drawPath(path, color, style = Stroke(1.5.dp.toPx(), cap = StrokeCap.Round))
        }
    }
}

@Composable
private fun SavedFlourish(contentDescription: String, modifier: Modifier = Modifier) {
    var visible by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        visible = true
        delay(900)
        visible = false
    }
    val alpha by animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = tween(DesignTokens.Motion.feedbackMillis),
        label = "savedFlourishAlpha"
    )
    val color = MaterialTheme.colorScheme.tertiary
    Canvas(
        modifier
            .semantics { this.contentDescription = contentDescription }
            .graphicsLayer { this.alpha = alpha }
    ) {
        val path = Path().apply {
            moveTo(size.width * 0.10f, size.height * 0.56f)
            lineTo(size.width * 0.40f, size.height * 0.82f)
            lineTo(size.width * 0.92f, size.height * 0.18f)
        }
        drawPath(path, color, style = Stroke(1.8.dp.toPx(), cap = StrokeCap.Round))
    }
}

@Composable
private fun rememberPressScale(interactionSource: MutableInteractionSource): Float {
    val pressed by interactionSource.collectIsPressedAsState()
    val animationsEnabled = LocalAnimationsEnabled.current
    return animateFloatAsState(
        targetValue = if (animationsEnabled && pressed) 0.97f else 1f,
        animationSpec = if (animationsEnabled) {
            tween(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing)
        } else {
            snap()
        },
        label = "writerActionPress"
    ).value
}
```

- [ ] **Step 2: Attach the title and save marks**

Place `TitleFocusMark` between the title field and the 8dp metadata gap:

```kotlin
TitleFocusMark(
    focused = titleFocused,
    modifier = Modifier.width(89.dp).height(5.dp)
)
```

Replace the saved `Icon` with a reduced-motion branch:

```kotlin
if (LocalAnimationsEnabled.current) {
    SavedFlourish(
        contentDescription = stringResource(R.string.editor_saved),
        modifier = Modifier.size(DesignTokens.Indicator.spinnerSm)
    )
} else {
    Icon(
        Icons.Default.Check,
        contentDescription = stringResource(R.string.editor_saved),
        tint = colorScheme.tertiary,
        modifier = Modifier.size(DesignTokens.Indicator.spinnerSm)
    )
}
```

- [ ] **Step 3: Attach press scale without changing layout**

After each existing interaction source, calculate its scale and apply it in `graphicsLayer` before background/clip:

```kotlin
val unBlockPressScale = rememberPressScale(unBlockInteractionSource)
// modifier:
.graphicsLayer {
    scaleX = unBlockPressScale
    scaleY = unBlockPressScale
}
```

Repeat with `micPillInteractionSource`. Retain ripple, click actions, semantics, animated widths, and recording state.

- [ ] **Step 4: Compile the changed Kotlin**

Run:

```bash
./gradlew :app:compileDebugKotlin
```

Expected: BUILD SUCCESSFUL with no Kotlin errors.

---

### Task 4: Settings rhythm and simplified appearance selector

**Files:**
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/AppearanceSelector.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SegmentedControl.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SettingsDialog.kt`
- Test: `android/app/src/androidTest/kotlin/com/rhymeai/app/AppearanceUiTest.kt`

**Interfaces:**
- Consumes: `DesignTokens.Rhythm`.
- Produces: a 42dp segmented track inside a 48dp hit area, one live appearance selector without preview cards, and a 55dp pinned Save action.

- [ ] **Step 1: Add a failing appearance-layout assertion**

In `AppearanceUiTest.appearanceSelectionAppliesImmediatelyAndPersistsAfterRelaunch`, after opening Settings, assert the selector exposes at least a 48dp hit target:

```kotlin
val selectorHeight = composeRule.onNodeWithTag("appearanceSelector")
    .getUnclippedBoundsInRoot()
    .height
assertTrue("Appearance selector needs a 48dp touch target", selectorHeight.value >= 48f)
```

Add the `getUnclippedBoundsInRoot` and `onNodeWithTag` imports.

- [ ] **Step 2: Run the appearance test to confirm red**

Run:

```bash
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rhymeai.app.AppearanceUiTest#appearanceSelectionAppliesImmediatelyAndPersistsAfterRelaunch
```

Expected: FAIL because the current selector is 40dp high.

- [ ] **Step 3: Remove the redundant preview strip**

In `AppearanceSelector.kt`, keep the label, 8dp spacer, and `SlidingSegmentedControl`. Delete the following spacer and preview `Row`; remove now-unused preview palette, shape, border, background, clip, height, padding, and `colorSchemeFor` imports.

- [ ] **Step 4: Make segmented controls visually 42dp with 48dp hit targets**

Set:

```kotlin
private val TrackHeight = 42.dp
```

Use an outer 48dp `Box` tagged by the caller and center the existing track drawing at 42dp. Keep the selection `Row` at 48dp so every segment's selectable hit area fills the full target; center the pill/background/dividers in the 42dp visual track.

- [ ] **Step 5: Apply Settings rhythm**

In `SettingsDialog.kt`:

```kotlin
.padding(horizontal = DesignTokens.Rhythm.standard)
.padding(top = DesignTokens.Rhythm.standard)
```

Use 21sp for the Settings title, 21dp around the primary tab control, 34dp between Appearance and AI Provider, 8dp between labels and segmented controls, 21dp between related form fields, and `Modifier.fillMaxWidth().height(DesignTokens.Rhythm.primary)` for Save Settings. Keep native text-field/dropdown heights unchanged at 56dp.

- [ ] **Step 6: Run the appearance test and capture screenshots**

Run the Step 2 command again. Expected: PASS and new Ink/Paper/Graphite Settings screenshots written by the existing test.

---

### Task 5: Integrated verification and debug APK

**Files:**
- Verify: all changed Android files
- Create artifact: `artifacts/rhymeai-phi-rhythm-writers-marks-debug-2026-07-11.apk`

**Interfaces:**
- Consumes: all previous tasks.
- Produces: a manually verified debug APK; it does not publish externally without additional user authorization.

- [ ] **Step 1: Run focused JVM tests and lint**

```bash
./gradlew :app:testDebugUnitTest --tests com.rhymeai.app.ui.screens.UnBlockSizingTest
./gradlew :app:lintDebug
```

Expected: BUILD SUCCESSFUL for both commands.

- [ ] **Step 2: Run focused instrumented tests serially**

```bash
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rhymeai.app.NewFeatureUiTest#lyricStatsSitBelowTheEditableTitle
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rhymeai.app.NewFeatureUiTest#editorActionsStayGroupedAtTheRightEdge
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rhymeai.app.AppearanceUiTest
```

Expected: all selected tests PASS.

- [ ] **Step 3: Build and install the exact artifact**

```bash
./gradlew :app:assembleDebug --rerun-tasks
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am force-stop com.rhymeai.app
adb shell monkey -p com.rhymeai.app -c android.intent.category.LAUNCHER 1
```

Expected: Gradle BUILD SUCCESSFUL, adb `Success`, and the launcher opens `MainActivity`.

- [ ] **Step 4: Perform the manual QA gate**

On the emulator:

1. Open a new song in Ink.
2. Focus the title and observe the 260ms underline draw.
3. Type a title and lyrics; confirm the 13sp stats update below the title and the saved flourish appears then fades.
4. Press and release UnBlock; confirm scale feedback without positional drift, then dismiss the assistant.
5. Press and release the microphone; deny or grant permission as needed and confirm the control stays right aligned.
6. Open Settings; verify the preview strip is gone, controls follow the new rhythm, and Save Settings is 55dp.
7. Repeat settled editor and Settings inspection in Paper and Graphite.
8. Set Android font size to its large accessibility tier and confirm title, stats, UnBlock, and settings labels do not clip.

- [ ] **Step 5: Run final repository and package checks**

```bash
git diff --check
apksigner verify --verbose app/build/outputs/apk/debug/app-debug.apk
adb shell pidof com.rhymeai.app
adb logcat -d -b crash
```

Expected: no whitespace errors, APK v2 signature verification succeeds, a package PID is returned, and the crash buffer is empty.

- [ ] **Step 6: Copy and checksum the APK**

Copy the verified build to `artifacts/rhymeai-phi-rhythm-writers-marks-debug-2026-07-11.apk` and run:

```bash
shasum -a 256 artifacts/rhymeai-phi-rhythm-writers-marks-debug-2026-07-11.apk
```

Report the exact path, size, and SHA-256. Do not create a release or push source unless the user explicitly asks.
