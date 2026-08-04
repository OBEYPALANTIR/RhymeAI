# Rewrite Motion Variants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build three optimized Android evaluation APKs whose only behavioral difference is the selected-lyric rewrite loading animation.

**Architecture:** A validated Gradle property becomes a typed `RewriteMotionStyle`. A focused Compose draw modifier renders Pencil Revision, Rhyme Ripple, or Paper Slip from the existing text-layout geometry and shared animation progress. The editor and rewrite state machine remain unchanged.

**Tech Stack:** Kotlin, Jetpack Compose draw modifiers, Gradle Kotlin DSL, Android instrumentation tests, adb emulator QA.

## Global Constraints

- Accepted values are exactly `pencil`, `ripple`, and `paper`.
- All variants use one 1.2-second repeating progress clock.
- The selected lyric must remain readable and surrounding text must not reflow.
- System-disabled animations render a stable non-looping treatment.
- No new runtime dependency is allowed.
- Do not commit or push the dirty worktree unless the user explicitly asks.

---

### Task 1: Typed build variant boundary

**Files:**
- Modify: `android/app/build.gradle.kts`
- Create: `android/app/src/main/kotlin/com/rhymeai/app/ui/motion/RewriteMotionStyle.kt`
- Create: `android/app/src/test/kotlin/com/rhymeai/app/ui/motion/RewriteMotionStyleTest.kt`

**Interfaces:**
- Consumes: Gradle property `rewriteMotionStyle`.
- Produces: `BuildConfig.REWRITE_MOTION_STYLE` and `RewriteMotionStyle.fromBuildValue(String)`.

- [x] Write tests asserting `pencil`, `ripple`, and `paper` parse to distinct exhaustive enum values and unknown values fail.
- [x] Run `./gradlew :app:testDebugUnitTest --tests com.rhymeai.app.ui.motion.RewriteMotionStyleTest` and confirm the missing type fails compilation.
- [x] Add the enum and strict parser.
- [x] Add Gradle property validation, BuildConfig field generation, and evaluation version-name suffixes.
- [x] Re-run the focused unit test and confirm it passes.

### Task 2: Focused rewrite loading renderer

**Files:**
- Create: `android/app/src/main/kotlin/com/rhymeai/app/ui/motion/RewriteLoadingHighlight.kt`
- Modify: `android/app/src/main/kotlin/com/rhymeai/app/ui/screens/EditorScreen.kt`

**Interfaces:**
- Consumes: `TextLayoutResult`, `TextRange`, loading/error flags, animation progress, `RewriteMotionStyle`, and themed highlight colors.
- Produces: `Modifier.rewriteLoadingHighlight(...)` with no layout changes.

- [x] Move the existing shared fill/error treatment and selected-line geometry into the focused modifier.
- [x] Implement Pencil Revision as a bounded irregular double underline plus flecks.
- [x] Implement Rhyme Ripple as two bounded phased sine strokes.
- [x] Implement Paper Slip as a bounded rounded strip, offset edge, and fold mark.
- [x] Replace the editor's old shimmer call with the typed renderer and keep the existing animation clock.
- [x] Run `./gradlew :app:compileDebugKotlin` and the focused unit test.

### Task 3: Build and identify all evaluation APKs

**Files:**
- Output: `artifacts/rewrite-motion-variants/rhymeai-pencil-revision-release.apk`
- Output: `artifacts/rewrite-motion-variants/rhymeai-rhyme-ripple-release.apk`
- Output: `artifacts/rewrite-motion-variants/rhymeai-paper-slip-release.apk`

**Interfaces:**
- Consumes: the three validated Gradle property values.
- Produces: three optimized, locally release-signed APKs with distinct version-name suffixes and filenames.

- [x] Build with `-PrewriteMotionStyle=pencil`, copy the exact APK, and record SHA-256.
- [x] Build with `-PrewriteMotionStyle=ripple`, copy the exact APK, and record SHA-256.
- [x] Build with `-PrewriteMotionStyle=paper`, copy the exact APK, and record SHA-256.
- [x] Verify each manifest version name and APK signature.

### Task 4: Emulator motion and interaction QA

**Files:**
- Evidence: `artifacts/rewrite-motion-variants/evidence/<style>/`

**Interfaces:**
- Consumes: each exact packaged APK and the existing debug rewrite-loading seed.
- Produces: fresh recordings, start/mid/loading frames, UI-tree evidence, and crash-log checks for all three variants.

- [x] Boot one Pixel emulator and normalize animation scales.
- [x] Install Pencil Revision, trigger seeded rewrite loading, and capture recording plus three frames.
- [x] Repeat the identical fixture and capture timing for Rhyme Ripple.
- [x] Repeat the identical fixture and capture timing for Paper Slip.
- [x] Run the existing rewrite loading and analysis interaction instrumentation tests.
- [x] Confirm the three captures differ only inside the selected lyric treatment.

### Task 5: Quality and handoff gate

**Files:**
- Verify: all source, tests, APKs, and evidence above.

**Interfaces:**
- Consumes: current source and fresh evidence.
- Produces: three verified APK links/paths and a concise comparison guide.

- [x] Run focused unit tests, Android lint, `git diff --check`, and fresh builds.
- [x] Dispatch the required read-only design-system and visual-fidelity reviewers over every variant's fresh evidence.
- [x] Fix and recapture any blocking visual finding until both reviewers pass.
- [x] Install each final copied APK and confirm the reported SHA matches the installed artifact.
- [x] Report the three paths, hashes, verification results, and any unrelated pre-existing test failure.
