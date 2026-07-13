# iOS UI Accessibility Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the audited iOS Dynamic Type, AI error recovery, drawer semantics, and Trash toast issues with regression coverage.

**Architecture:** Keep view state in the existing SwiftUI surfaces, add one pure error-recovery classifier for shared behavior, and add a DEBUG-only launch flag for deterministic accessibility UI tests. Use adaptive subviews instead of a broad navigation rewrite.

**Tech Stack:** Swift 5, SwiftUI, UIKit, Swift Testing, XCTest/XCUIApplication, Xcode 27 beta simulator tooling.

## Global Constraints

- Deployment target remains iOS 18.0.
- Preserve existing default-size geometry and dark/light styling.
- Use existing `RhymeAITokens` and native controls.
- Modify only iOS source, iOS tests, and these planning documents.
- Do not commit or push.

---

### Task 1: Test And Implement Shared AI Error Recovery

**Files:**
- Create: `Writers Block/Writers Block/Support/AIErrorRecoveryAction.swift`
- Create: `Writers Block/Writers BlockTests/AIErrorRecoveryActionTests.swift`
- Modify: `Writers Block/Writers Block/Views/AssistantPanelView.swift`
- Modify: `Writers Block/Writers Block/Views/EditorView.swift`
- Modify: `Writers Block/Writers BlockUITests/Writers_BlockUITests.swift`

**Interfaces:**
- Produces: `enum AIErrorRecoveryAction { case retry, openSettings; init(errorMessage: String) }`.
- Consumes: `EditorViewModel.showAssistantSheet`, `EditorViewModel.showSettingsSheet`, and the existing retry closures.

- [ ] **Step 1: Write failing classifier and UI tests**

```swift
@Test func missingAPIKeyRequiresSettings() {
    #expect(AIErrorRecoveryAction(errorMessage: "No API key set. Go to Settings.") == .openSettings)
}

@Test func connectionFailureAllowsRetry() {
    #expect(AIErrorRecoveryAction(errorMessage: "Check your connection.") == .retry)
}
```

Add UI assertions that a missing-key assistant/rewrite failure exposes `Open Settings`, opens `Settings`, and does not expose Retry.

- [ ] **Step 2: Run focused tests and verify RED**

Run the classifier test target and the two new UI tests. Expected: compilation failure because `AIErrorRecoveryAction` and `Open Settings` do not exist.

- [ ] **Step 3: Implement minimal shared recovery behavior**

Create the classifier, render `Open Settings` for `.openSettings`, preserve Retry for `.retry`, and present Settings after dismissing the phone assistant.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the same unit and UI tests. Expected: all focused tests pass.

### Task 2: Test And Implement Dynamic Type Reflow

**Files:**
- Modify: `Writers Block/Writers Block/Support/UITestFlags.swift`
- Modify: `Writers Block/Writers Block/Writers_BlockApp.swift`
- Modify: `Writers Block/Writers Block/Views/WelcomeView.swift`
- Modify: `Writers Block/Writers Block/Views/EditorView.swift`
- Modify: `Writers Block/Writers Block/Components/LyricsTextView.swift`
- Modify: `Writers Block/Writers Block/Components/RhymeHighlightedText.swift`
- Modify: `Writers Block/Writers Block/Components/SyllableColoredText.swift`
- Modify: `Writers Block/Writers BlockUITests/Writers_BlockUITests.swift`

**Interfaces:**
- Produces: `UITestFlags.accessibilityTextSize` and an app-root `.accessibility2` Dynamic Type override in DEBUG UI tests.
- Consumes: SwiftUI `dynamicTypeSize` and UIKit `UIFontMetrics`.

- [ ] **Step 1: Write failing accessibility-size UI tests**

Launch with `--ui-test-accessibility-text-size`; assert complete Welcome action labels, enter New Song, and assert drawer/export/settings plus microphone and assistant controls remain accessible.

- [ ] **Step 2: Run focused UI tests and verify RED**

Expected: the flag has no effect and geometry/frame assertions fail at accessibility size.

- [ ] **Step 3: Implement adaptive Welcome, Editor toolbar, floating actions, and lyric fonts**

Use a `ScrollView` and accessibility card layout in Welcome, a two-row accessibility toolbar in Editor, icon-only floating actions with full accessibility labels, and `UIFontMetrics` for UIKit lyric text. Replace fixed SwiftUI lyric fonts with `.body`-relative fonts.

- [ ] **Step 4: Run focused UI tests and verify GREEN**

Expected: Welcome and Editor accessibility tests pass on iPhone 17 Pro.

### Task 3: Test And Implement Drawer And Trash Semantics

**Files:**
- Modify: `Writers Block/Writers Block/Views/ProjectsDrawerView.swift`
- Modify: `Writers Block/Writers BlockUITests/Writers_BlockUITests.swift`

**Interfaces:**
- Produces: separate `Close drawer`, conditional `Clear search`, and `Move <title> to Trash` controls.
- Consumes: the existing `closeDrawer`, `showUndoToast`, and `trashBinPresented` flows.

- [ ] **Step 1: Write failing drawer/trash UI tests**

Assert Close exists while Clear is absent for empty search, Clear appears after typing, the row exposes `Move UI Trash Song to Trash`, and Undo is absent once Trash is visible.

- [ ] **Step 2: Run focused UI tests and verify RED**

Expected: control-label and toast assertions fail against the current drawer.

- [ ] **Step 3: Implement the minimal semantic changes**

Move close into a separate 44-point button, conditionally render the clear button, change the destructive glyph/label, and clear `undoToast` before setting `trashBinPresented = true`.

- [ ] **Step 4: Run focused UI tests and verify GREEN**

Expected: drawer/trash tests pass.

### Task 4: Full Verification And Visual Audit

**Files:**
- Verify all modified iOS files and screenshot artifacts outside the repository.

**Interfaces:**
- Consumes: completed Tasks 1-3.
- Produces: build/test results and default/light/dark/Accessibility XXL screenshots.

- [ ] **Step 1: Run all iOS unit tests**

Run `xcodebuild test` for `Writers BlockTests`. Expected: zero failures, with any known live-provider gate reported separately if encountered.

- [ ] **Step 2: Run all iPhone UI tests**

Run `xcodebuild test` for `Writers BlockUITests` on the booted iPhone 17 Pro. Expected: zero unexpected failures; live-key tests may skip when no key is configured.

- [ ] **Step 3: Build the Debug app**

Run `xcodebuild build` for the iPhone 17 Pro simulator. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Capture and inspect screenshots**

Capture Welcome, Editor, assistant error, drawer, and Trash in dark/light default size and Accessibility XXL. Reject loading, clipped, or wrong-state images.

- [ ] **Step 5: Confirm scope and working tree**

Run `git diff --check`, `git status --short`, and inspect the diff to ensure no Android files changed and no generated/debug files entered the repository.
