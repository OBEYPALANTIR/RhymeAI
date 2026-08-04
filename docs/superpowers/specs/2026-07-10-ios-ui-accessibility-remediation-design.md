# iOS UI Accessibility Remediation Design

## Objective

Bring the audited iPhone surfaces up to a reliable accessibility baseline without redesigning RhymeAI or changing Android behavior.

## Scope

- Make Welcome and Editor usable at accessibility Dynamic Type sizes.
- Scale the UIKit lyric editor with the user's preferred content size.
- Give missing-API-key errors an actionable route to Settings instead of a guaranteed-to-fail retry.
- Separate drawer dismissal from search clearing and replace the ambiguous destructive `x` with a trash affordance.
- Remove the drawer Undo toast before entering Trash so it cannot cover Restore/Delete.
- Add focused UI and unit regression coverage for the new behavior.

## Layout Design

### Welcome

Wrap the existing welcome composition in a vertical `ScrollView`. At accessibility Dynamic Type sizes, reduce decorative spacing, allow the introduction to grow without truncation, and use full-width action cards whose title and subtitle wrap vertically inside the card. Default-size geometry remains visually unchanged.

### Editor

Read `dynamicTypeSize` from the environment. Keep the current single-row top bar at standard sizes. At accessibility sizes, use a two-row bar: navigation/title/save status on the first row and counts/export/settings on the second. Floating microphone and UnBlock actions become icon-only 56-point controls at accessibility sizes while retaining explicit accessibility labels. The editable lyric text uses `UIFontMetrics(forTextStyle: .body)` and `adjustsFontForContentSizeCategory` so content scales with system settings.

## Error Recovery

Introduce a small `AIErrorRecoveryAction` classifier that maps missing-key messages to `.openSettings` and all other failures to `.retry`. Assistant and inline rewrite error UI consume this shared classification. Missing-key errors display an `Open Settings` action; other transient failures retain Retry. Opening Settings dismisses the phone assistant first and presents Settings on the next main-actor turn.

## Drawer And Trash

The drawer search field only shows Clear Search when text exists. A separate 44-point Close button sits beside the search field at all times. Project rows use a trash icon and the accessibility label `Move <title> to Trash`. Entering Trash clears the Undo toast because the Trash screen itself provides restoration controls.

## Testing

- Unit-test `AIErrorRecoveryAction` classification.
- Add a UI-test-only Dynamic Type override and assert the accessibility Welcome and Editor expose all primary actions without truncating their accessibility labels.
- Add UI tests for Open Settings recovery from assistant and rewrite failures.
- Add UI tests for separate Close/Clear controls, the trash affordance, and toast removal after Trash opens.
- Run the focused tests red before implementation, green after implementation, then run the full iOS unit/UI suite, a simulator build, and dark/light Accessibility XXL screenshot verification.

## Constraints

- iOS deployment target remains 18.0.
- Use native SwiftUI/UIKit controls and existing RhymeAI tokens.
- Respect Reduce Motion and current dark/light styling.
- Do not modify Android files.
- Do not commit or push without explicit user instruction.
