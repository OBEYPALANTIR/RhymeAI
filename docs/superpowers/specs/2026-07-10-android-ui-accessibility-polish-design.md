# Android UI Accessibility Polish Design

Date: 2026-07-10
Status: Implemented and verified
Scope: Android only

## Goal

Resolve the seven UI and accessibility gaps confirmed in the Pixel emulator audit without changing RhymeAI's established visual hierarchy, segmented-control geometry, editor workflow, or persistence behavior.

## Success Criteria

1. Every settings switch has a stable accessible name in addition to its switch role and on/off state.
2. Trash selection exposes one focusable checkbox-style control per selectable row, with an accessible name and selected state.
3. The trash entry button exposes exactly one accessibility node named `Open Trash Bin`.
4. The UnBlock wordmark remains fully visible at Android font scale 2.0 while retaining the existing recording-collapse animation.
5. The assistant sheet has an explicit 48 dp close action while retaining drag-to-dismiss and system Back behavior.
6. Project search clearing and drawer dismissal are separate visible actions.
7. Song-row deletion uses a trash icon while preserving the existing move-to-trash and Undo behavior.

## Non-Goals

- No iOS changes.
- No redesign of the editor, settings, assistant content, project rows, or trash flow.
- No change to the shared `SlidingSegmentedControl` geometry or animation.
- No provider, model, persistence, recording, or AI-generation behavior changes.
- No dependency upgrades or broad lint cleanup.

## Design Decisions

### Settings switch semantics

`EditorToggleRow` will always apply the visible `label` as the switch's accessible name. The role, checked state, and toggle action remain provided by Material 3 `Switch`; the description will not include the word `Toggle`, because the accessibility service already announces the control role and action.

The optional `contentDescription` parameter will be removed so all six rows follow one rule and cannot drift again.

### Trash selection semantics

Each selection header, project row, and recording row will become a single `toggleable` element with `Role.Checkbox`. The row will expose its visible identifying text as the accessible name, and the toggleable state will announce selected or not selected.

`SelectionCircle` will remain the visual indicator but will no longer be independently clickable or focusable. This removes the duplicate nested action and ensures one accessibility stop per selectable row.

Names:

- Header: `All items`
- Project: project title, falling back to `Untitled Song`
- Recording: recording display name

### Trash entry semantics

The `OutlinedIconButton` remains the single semantic owner of `Open Trash Bin`. Its child icon becomes decorative with `contentDescription = null`.

### Adaptive UnBlock sizing

The existing explicit-width transition remains because recording mode animates the UnBlock pill into a 56 dp circle. `rememberTextMeasurer` will measure the actual `UnBlock` text with the same style used for rendering. A small pure helper will calculate the resting button width from that measured width plus the existing icon, gap, and horizontal breathing room. The result will keep the current 150 dp minimum so normal-size geometry is unchanged, then cap at the action row's available width after reserving the microphone width and inter-button gap.

The animated wordmark clipping box will use the same measured text width instead of the fixed 76 dp value. The scribble remains 68 dp wide and centered under the wordmark.

At font scale 2.0, the button may become wider but must remain centered with the microphone action and fit the phone viewport without overlap.

### Assistant close action

The drag-handle area will become a layered header:

- The drag handle stays centered and retains the existing vertical drag gesture.
- A 48 dp `IconButton` with `Close assistant` semantics is aligned to the trailing edge.
- Activating it uses the existing animated dismissal path, matching Back and drag dismissal.

### Search and drawer dismissal

The project drawer header will use a row containing:

- A weighted search field.
- A separate 48 dp close button labeled `Close drawer`.

The search field shows a trailing clear action only while the query is non-empty. Clearing the query never closes the drawer, and the dedicated close action never changes meaning.

### Song delete icon

The existing red close/X icon on song rows will be replaced with the Material delete/trash icon. The `Delete <title>` accessible name, move-to-trash behavior, and Undo snackbar remain unchanged.

## Testing Strategy

### Instrumented Compose tests

Add focused tests to `NewFeatureUiTest` that verify:

- All six editor switches are discoverable by their accessible names.
- The trash entry description appears exactly once.
- Trash header/project/recording selectors expose checkbox roles and toggle state without a second nested clickable node.
- The assistant close action is displayed, dismisses the sheet, and returns focusable editor actions.
- The drawer close action exists independently of `Clear search`; typing and clearing a query leaves the drawer open.
- Song deletion remains reachable through the renamed trash icon action.
- The existing stale trash test is updated to the current direct move-to-trash plus Undo behavior; no confirmation is reintroduced for recoverable deletion.

### Width calculation test

Keep the width calculation in a small deterministic helper that accepts the measured wordmark width, and add a JVM unit test proving:

- A normal measured wordmark keeps the 150 dp minimum.
- A doubled measured wordmark requests enough width for the label and never returns less than the minimum.

### Emulator verification

On the Pixel 10 Pro XL emulator:

1. Build and install the debug APK.
2. Inspect UI trees for settings, projects, assistant, and trash.
3. Confirm one accessibility node per fixed control.
4. Capture editor screenshots at font scales 1.0 and 2.0 in light mode.
5. Confirm the UnBlock wordmark is fully visible at 2.0 and does not overlap the microphone action.
6. Check dark mode for regressions.
7. Exercise delete, Undo, trash selection, and permanent-delete confirmation with test data only.

## Verification Commands

From `android/`:

```sh
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:compileDebugKotlin
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:testDebugUnitTest
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:lintDebug
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:assembleDebug
```

Run the focused instrumentation tests on the available emulator, followed by the manual emulator checks above. If the repository exposes `check`, `detekt`, `spotlessApply`, or Roborazzi tasks, run the applicable configured tasks without introducing new tooling.

## Risks and Mitigations

- Adaptive UnBlock width could crowd compact screens. Calculate its maximum as `row width - microphone width - inter-button gap`, then verify at 2.0 font scale that the measured label still fits without overlap.
- Consolidating trash click targets could alter selection behavior. Keep the row-wide toggle behavior and verify header, individual selection, restore, and delete states.
- Adding a close button to the assistant handle could intercept drag gestures. Limit the button to its 48 dp trailing area and retain drag handling on the remaining header.
- Separating search and close reduces search-field width. Preserve the current 48 dp close target and verify placeholder and query text at 2.0 font scale.

## Implementation Boundaries

Expected production files:

- `android/app/src/main/kotlin/com/rhymeai/app/ui/components/SettingsDialog.kt`
- `android/app/src/main/kotlin/com/rhymeai/app/ui/components/ProjectsDialog.kt`
- `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt`
- `android/app/src/main/kotlin/com/rhymeai/app/ui/theme/DesignTokens.kt` only if a reusable spacing token is required

Expected test files:

- `android/app/src/androidTest/kotlin/com/rhymeai/app/NewFeatureUiTest.kt`
- A focused JVM test under `android/app/src/test/kotlin/com/rhymeai/app/ui/` for adaptive UnBlock width calculation
