# Android UI Accessibility Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the audited Android editor, drawer, settings, assistant, and trash controls accessible and resilient at 200% font scale without redesigning the existing UI.

**Architecture:** Preserve the current Compose screens and state flow. Consolidate semantics at each actionable container, make decorative children non-focusable, and isolate UnBlock width arithmetic in a pure helper while measuring the rendered wordmark in `EditorScreen`.

**Tech Stack:** Kotlin 2.3.20, Jetpack Compose Material 3, Compose UI tests, Kotlin/JVM tests, Gradle 9, adb emulator QA.

## Global Constraints

- Android only; no iOS changes.
- Preserve `SlidingSegmentedControl` geometry and animation.
- Preserve editor, persistence, AI, recording, and trash-retention behavior.
- Keep every interactive target at least 48 dp.
- Recoverable song deletion remains immediate with an Undo snackbar.
- Use test-first red-green cycles before each production change.

---

### Task 1: Adaptive UnBlock width

**Files:**
- Create: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/UnBlockSizing.kt`
- Create: `android/app/src/test/kotlin/com/rhymeai/app/ui/screens/UnBlockSizingTest.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/DesignTokens.kt`

**Interfaces:**
- Produces: `internal fun unBlockButtonWidth(measuredWordmarkWidth: Dp, maxAvailableWidth: Dp): Dp`
- Produces: `internal fun unBlockWordmarkWidth(measuredWordmarkWidth: Dp): Dp`
- Consumes: `DesignTokens.EditorChrome` icon, gap, minimum width, and microphone width values.

- [ ] **Step 1: Write failing JVM tests for normal and doubled wordmark widths**

```kotlin
class UnBlockSizingTest {
    @Test
    fun normalWordmarkKeepsExistingMinimumWidth() {
        assertEquals(150.dp, unBlockButtonWidth(60.dp, 300.dp))
    }

    @Test
    fun doubledWordmarkExpandsWithoutExceedingAvailableWidth() {
        assertEquals(178.dp, unBlockButtonWidth(120.dp, 240.dp))
        assertEquals(160.dp, unBlockButtonWidth(120.dp, 160.dp))
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:testDebugUnitTest --tests 'com.rhymeai.app.ui.screens.UnBlockSizingTest'`

Expected: compilation failure because `unBlockButtonWidth` does not exist.

- [ ] **Step 3: Add the pure sizing helpers**

```kotlin
internal fun unBlockWordmarkWidth(measuredWordmarkWidth: Dp): Dp =
    maxOf(DesignTokens.EditorChrome.unBlockScribbleWidth, measuredWordmarkWidth)

internal fun unBlockButtonWidth(
    measuredWordmarkWidth: Dp,
    maxAvailableWidth: Dp
): Dp {
    val desired = DesignTokens.EditorChrome.unBlockIconSize +
        DesignTokens.EditorChrome.unBlockWordmarkGap +
        unBlockWordmarkWidth(measuredWordmarkWidth) +
        DesignTokens.EditorChrome.unBlockHorizontalPadding
    return desired
        .coerceAtLeast(DesignTokens.EditorChrome.unBlockExtendedWidth)
        .coerceAtMost(maxAvailableWidth)
}
```

- [ ] **Step 4: Measure the wordmark and feed the animated widths**

Use `rememberTextMeasurer()` with the same `TextStyle` and `FontWeight.Medium` as `UnBlockWordmark`. Convert the measured pixel width to dp. Calculate `maxAvailableWidth` as `configuration.screenWidthDp.dp - DesignTokens.EditorChrome.micRecordingRestWidth - DesignTokens.Spacing.sm - (DesignTokens.Spacing.lg * 2)`, and replace both fixed resting targets with the helpers. Add `unBlockScribbleWidth = 68.dp`, `unBlockHorizontalPadding = 32.dp`, and `micRecordingRestWidth = fabSize` to `DesignTokens.EditorChrome`. Add `testTag("unBlockAction")` and `testTag("unBlockWordmark")` for bounds verification.

- [ ] **Step 5: Run focused and full JVM tests and confirm GREEN**

Run the focused test command, then `./gradlew :app:testDebugUnitTest` with the configured JBR.

Expected: all unit tests pass.

- [ ] **Step 6: Commit the sizing change**

```sh
git add android/app/src/main/kotlin/com/rhymeai/app/ui/screens/UnBlockSizing.kt \
  android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt \
  android/app/src/main/kotlin/com/rhymeai/app/ui/theme/DesignTokens.kt \
  android/app/src/test/kotlin/com/rhymeai/app/ui/screens/UnBlockSizingTest.kt
git commit -m "fix(ui): scale UnBlock action with text size"
```

### Task 2: Settings and trash semantics

**Files:**
- Modify: `android/app/src/androidTest/kotlin/com/rhymeai/app/NewFeatureUiTest.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SettingsDialog.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/ProjectsDialog.kt`

**Interfaces:**
- Settings switches expose the visible label as `contentDescription`.
- Trash selection rows expose `Role.Checkbox` and `ToggleableState` through `Modifier.toggleable`.
- `SelectionCircle(selected: Boolean)` is visual-only.

- [ ] **Step 1: Add failing instrumented semantics tests**

Add tests that open Settings → Editor and assert all six switch descriptions exist. Add a trash test that deletes a test song, opens Trash, asserts the project row has checkbox role/off state, clicks it, and asserts on state. Assert `Open Trash Bin` occurs once with `useUnmergedTree = true`.

```kotlin
val selector = composeRule.onNodeWithContentDescription("UI Trash Song")
val before = selector.fetchSemanticsNode().config
assertEquals(Role.Checkbox, before[SemanticsProperties.Role])
assertEquals(ToggleableState.Off, before[SemanticsProperties.ToggleableState])
selector.performClick()
selector.assertIsOn()
```

- [ ] **Step 2: Run the focused instrumentation tests and confirm RED**

Run: `./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.rhymeai.app.NewFeatureUiTest`

Expected: missing settings descriptions, duplicate trash description, and absent checkbox semantics.

- [ ] **Step 3: Make every settings switch use its label**

Remove `contentDescription` from `EditorToggleRow` parameters and apply `Modifier.semantics { contentDescription = label }` to every `Switch`.

- [ ] **Step 4: Consolidate trash selection into row toggleables**

Replace row/header `clickable` modifiers with:

```kotlin
.toggleable(
    value = selected,
    role = Role.Checkbox,
    onValueChange = { onToggle() }
)
.semantics { contentDescription = accessibleName }
```

Remove `onToggle` and `.clickable` from `SelectionCircle`, leaving its 48 dp visual container and animation intact. Set the trash icon child description to `null` while keeping the parent `Open Trash Bin` description.

- [ ] **Step 5: Update the stale recoverable-delete UI test**

Remove the obsolete `Move to Trash` confirmation click. Assert the snackbar text and Undo action after `Delete UI Trash Song`, then continue into Trash after the snackbar settles.

- [ ] **Step 6: Run focused instrumentation tests and confirm GREEN**

Expected: settings labels, checkbox role/state, single trash node, and delete/Undo flow pass.

- [ ] **Step 7: Commit semantic fixes**

```sh
git add android/app/src/main/kotlin/com/rhymeai/app/ui/components/SettingsDialog.kt \
  android/app/src/main/kotlin/com/rhymeai/app/ui/components/ProjectsDialog.kt \
  android/app/src/androidTest/kotlin/com/rhymeai/app/NewFeatureUiTest.kt
git commit -m "fix(ui): expose accessible control semantics"
```

### Task 3: Explicit drawer and assistant actions

**Files:**
- Modify: `android/app/src/androidTest/kotlin/com/rhymeai/app/NewFeatureUiTest.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/components/ProjectsDialog.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt`

**Interfaces:**
- Drawer exposes separate `Clear search` and `Close drawer` nodes.
- Assistant exposes `Close assistant` and reuses `dismissAssistantSheet()`.
- Song rows preserve `Delete <title>` semantics with a delete icon.

- [ ] **Step 1: Add failing navigation and affordance tests**

Add tests that verify: drawer Close exists with an empty query; Clear appears only after text input and clearing leaves the drawer visible; Close dismisses the drawer; assistant Close dismisses the assistant; delete action still exists by content description.

- [ ] **Step 2: Run focused instrumentation tests and confirm RED**

Expected: separate close/clear and assistant close nodes are missing.

- [ ] **Step 3: Split drawer search and close controls**

Wrap the search field and a 48 dp close `IconButton` in a `Row` with 8 dp spacing. Give the field `weight(1f)`. Render the trailing Clear icon only when `searchQuery.isNotEmpty()`; the dedicated close button always calls `closeDrawer()`.

- [ ] **Step 4: Add the assistant close action**

Keep the drag gesture on the 64 dp handle area. Layer the centered handle and a trailing 48 dp `IconButton` in the existing `Box`; its close icon uses `contentDescription = "Close assistant"` and calls `dismissAssistantSheet()`.

- [ ] **Step 5: Replace the song-row X icon**

Change `Icons.Default.Close` to `Icons.Default.Delete` in `ProjectDrawerRow` without changing its callback or `Delete <title>` description.

- [ ] **Step 6: Run focused instrumentation tests and confirm GREEN**

Expected: all new navigation/affordance tests pass.

- [ ] **Step 7: Commit affordance fixes**

```sh
git add android/app/src/main/kotlin/com/rhymeai/app/ui/components/ProjectsDialog.kt \
  android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt \
  android/app/src/androidTest/kotlin/com/rhymeai/app/NewFeatureUiTest.kt
git commit -m "fix(ui): clarify drawer and assistant actions"
```

### Task 4: Full verification, APK, and GitHub publication

**Files:**
- Modify: `docs/superpowers/specs/2026-07-10-android-ui-accessibility-polish-design.md` status only
- Modify: `docs/superpowers/plans/2026-07-10-android-ui-accessibility-polish.md` checkbox status only
- Build artifact: `android/app/build/outputs/apk/debug/app-debug.apk`

- [ ] **Step 1: Run repository checks**

Run `./gradlew check`, `./gradlew lint`, `./gradlew detekt`, `./gradlew spotlessApply`, and `./gradlew recordRoborazziDebug` when those tasks exist; skip only tasks absent from `./gradlew tasks --all`. Run `:app:connectedDebugAndroidTest` on the active emulator.

- [ ] **Step 2: Run emulator QA at normal font scale**

Install the debug APK, launch the app, capture UI trees and screenshots for editor, settings, drawer, assistant, and trash, and verify the new descriptions and checkbox states.

- [ ] **Step 3: Run 200% text and dark-mode QA**

Set font scale to 2.0, confirm the UnBlock label is fully visible and does not overlap the microphone, capture evidence, then test dark mode. Restore font scale 1.0 and the original UI mode.

- [ ] **Step 4: Build and fingerprint the fresh APK**

```sh
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:assembleDebug
shasum -a 256 app/build/outputs/apk/debug/app-debug.apk
```

Record APK size, SHA-256, version name/code, branch, and commit.

- [ ] **Step 5: Commit documentation status and verify the branch**

Stage the spec/plan status changes, commit with `chore(ui): document accessibility polish`, then confirm `git status --short` is clean and `git log` contains all intended commits.

- [ ] **Step 6: Push and upload the APK**

Push the `codex/android-ui-accessibility-polish` branch. Create a GitHub release tag derived from the date and final short commit, attach the exact fingerprinted APK as `rhymeai-android-debug.apk`, and verify the remote release asset size and download URL.
