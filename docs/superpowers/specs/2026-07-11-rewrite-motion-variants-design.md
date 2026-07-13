# Rewrite Motion Variant Builds

## Goal

Produce three optimized Android evaluation APKs that differ only in the loading animation shown over a selected lyric while an AI rewrite is being generated. The builds let the motion character be judged without changing rewrite behavior, controls, typography, color settings, or result handling.

## Shared comparison contract

- All three builds use the same editor, selected lyric, loading duration, colors, rewrite request, inline result, and review controls.
- Each build uses the same 1.2-second repeating progress clock and stops motion when system animations are disabled.
- The selected text remains readable throughout the animation.
- Motion stays inside the selected line bounds and must not move surrounding lyrics or change editor layout.
- Error rendering remains the existing error fill and stroke in every build.
- The three APKs use the same application ID and install one at a time. Their filenames and evaluation version-name suffixes identify the variant.

## Variant A: Pencil Revision

The selected phrase receives a quiet graphite fill. A slightly irregular double-stroke underline draws from left to right, followed by two small graphite flecks. The underline is the primary action; the second stroke and flecks provide handmade character without obscuring the lyric.

Emotional target: deliberate, authored, tactile.

## Variant B: Rhyme Ripple

The selected phrase receives a quiet fill while two thin sine-wave strokes move beneath it with a small phase offset. The waves remain horizontally bounded to the selection and read as sound or rhyme energy rather than a generic loading shimmer.

Emotional target: musical, connected, energetic.

**Selected direction:** Rhyme Ripple is the production default on Android and iOS. Pencil Revision and Paper Slip remain available only as evaluation references.

## Variant C: Paper Slip

A rounded paper strip slides a few pixels into place behind each selected line. A soft offset edge and a small folded-corner mark create the impression that the phrase has lifted from the page. The strip settles rather than bouncing.

Emotional target: charming, physical, editorial.

## Architecture

- Gradle defaults to `ripple`; `-PrewriteMotionStyle=pencil|ripple|paper` remains a validated evaluation override, writes `BuildConfig.REWRITE_MOTION_STYLE`, and adds the style to evaluation build version names.
- `RewriteMotionStyle` parses the build value into an exhaustive enum.
- A focused `RewriteLoadingHighlight.kt` draw modifier owns selection geometry and the three renderers. `EditorScreen.kt` only supplies text layout, range, loading/error state, progress, and theme colors.
- iOS draws the selected Ripple treatment from the existing `RewriteHighlightOverlayView`, using the same 1.2-second phase loop and a stable frame when Reduce Motion is enabled.
- Existing rewrite state and networking remain untouched.

## Accessibility and performance

- With animations disabled, every style renders a stable selected-state treatment with no infinite transition.
- Drawing uses existing `TextLayoutResult` geometry and does not trigger text re-layout.
- No particles, blur, or bitmap allocation is performed per frame.
- Every animated line is bounded; long multi-line selections do not animate outside their selected lines.

## Verification

- Unit tests cover build-style parsing and exhaustive identifiers.
- The existing rewrite-loading instrumentation path is run for each APK.
- Each variant receives a fresh screen recording plus start, mid, and settled/loading frames on the same emulator and lyric fixture.
- Targeted tests, lint, APK signing verification, install/launch, and crash-log checks run before handoff.

## Out of scope

- The result-arrival replacement animation is intentionally unchanged so this comparison isolates the loading treatment.
- The unselected Pencil Revision and Paper Slip treatments are not exposed as iOS variants.
- The builds are locally release-signed evaluation artifacts, not Play Store releases.
