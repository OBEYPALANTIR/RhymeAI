# Release Notes

## iPad works in narrow windows and reads better with VoiceOver (iOS)

In Split View, Stage Manager and resized windows narrower than 760 points, the
editor keeps the full window and the Assistant opens as the panel that rises
from the bottom, instead of squeezing the lyrics beside a fixed column; widen
the window and the column comes back. At the largest text sizes the
Assistant's labels sit above their controls, so words such as "Target" and
"Rhyme" are no longer split. Secondary text is darker so it is easier to read,
the Trash screen's Delete button is readable on Graphite, the songs drawer has
a visible edge on Graphite, and the Assistant header is flat like the editor's
toolbar. With VoiceOver, the editor is hidden while the songs drawer is open,
the dimmed area closes the drawer, and showing or hiding the Assistant is
announced.

## iPad layout sits on the golden ratio (iOS)

On iPad the Assistant column and the songs drawer now take the smaller golden
share of the screen. The Assistant column is never narrower than before, so in
landscape it is wider and the lyrics keep a comfortable column. The songs drawer
opens as a side panel instead of covering the whole screen; tap outside it to
close. At standard text sizes the Assistant header lines up with the editor's
toolbar. The Rhyme Options summary takes priority over its title, so the title
shortens first. The lyrics share the Assistant's side margin, the Trash screen
keeps to a centred column, and the Word Inspector opens centred.

## The rhyme you are matching is marked in violet (iOS and Android)

With rhyme highlighting on, the last word of the Target Line and of each suggestion is now violet, semibold and underlined, so the sound being matched is easy to spot.

## The Assistant is spaced on a golden-ratio rhythm (iOS and Android)

The Assistant panel and its suggestion cards now use one spacing scale of 8,
13, 21, 34 and 55 points, each step with one job: tight inside a control,
related between a heading and what it labels, standard inside and between
cards, a wider step between sections, and the most room above the main button.
The placeholder card is now exactly as tall as a one-line suggestion, so the
list no longer shifts when a line arrives. On Android, keyboard focus now shows
on the selected option of a segmented control, and the UnBlock label fades
away completely before the button shrinks when recording starts.

## Placeholders scribble while suggestions are written, and the spinner bursts when they are done (iOS and Android)

While the model writes, the one placeholder card waiting for the next line now
scribbles two wavy pencil lines in, holds them a moment, wipes them and starts
again, so a slow model still looks busy. Each line fades into the
placeholder's place without moving, and a placeholder left empty when writing
stops fades away as before. When writing finishes with at least one line, the
Stop spinner bursts into a small spray of ink as the button turns back into
Suggest Next Line; tapping Stop, changing a setting or editing mid-stream, an
error or an empty answer does not burst.
With Reduce Motion on (iOS) or animations removed (Android) the scribble holds
still, there is no burst, and lines simply appear.

## Suggestions hold their places while they are written (iOS and Android)

Tapping Suggest Next Line now opens the Suggestions list straight away with
one placeholder card where the first line will go, with a faint ink line
that is written once and then waits, and a "Writing…" note beside the heading.
Each line fades and rises into the placeholder's place as it arrives, and the next
placeholder opens below it while the model is still writing, so only one
waits at a time. Placeholders follow your text size, so the list only moves
when a line runs onto a second line, at large text sizes too. The placeholder
still waiting when the model finishes or you tap Stop fades away. VoiceOver announces "Writing suggestions" and TalkBack reads the
note. With Reduce Motion on (iOS) or animations removed (Android) the
placeholders keep still and lines simply appear.

## Pending rewrite highlight is still and monochrome (iOS and Android)

While a Harder Rhyme, Punch Up or other rewrite is being written, the selected
lyric now keeps a plain highlight in the appearance's selection colour with a
thin outline, the same tint as an ordinary selection. The moving indigo band on
iOS and the green outline on Android are gone; the rewrite bar at the bottom
still shows that the rewrite is in progress. A failed rewrite keeps its red
highlight.

## Pending next-line suggestions follow the selected rhyme scheme (iOS and Android)

Suggest Next Line now works out the rhyme for the line it is about to add, not
for the line the cursor is on. With ABAB and two lines written, the suggestion
is the third line and rhymes with line 1; before, it was asked to start a new
sound. The Target Line card and the scheme preview show the same letter and
rhyme line that are sent to the model, and the preview marks the row where the
new line will go ("Next line goes here").

"Use line" puts the suggestion on the empty line the cursor is on, or on a new
line directly after the cursor's line. It no longer splits a lyric line when the
cursor is in the middle of it, and no longer leaves an extra blank line when a
line is added between existing lines.

A section header such as [Chorus] now starts a new stanza for the rhyme scheme
even without a blank line above it, so a suggestion never rhymes across a
header or a blank line. On Android a line containing only spaces now separates
stanzas, as it already did on iOS. In a stanza longer than the scheme, the
scheme repeats (the fifth line of AABB is "A" and rhymes with line 2).

## Pending Android lyric analysis and editor fixes

The Ink Marks analysis style has been removed from Android. Lyric analysis is
always shown in colour, the Analysis Style control is gone from the Editor tab
of Settings, and the Rhyme Families and Syllable Guide switches are unchanged.
If Ink Marks was selected in an earlier version, the app now simply uses
colour; no other setting is changed.

Words keep their syllable and rhyme colours while text is selected; the
selection highlight sits behind the coloured words. Focus mode still removes
analysis colour.

Selecting lyrics now hides the UnBlock and mic buttons while the rewrite bar is
showing, for screen readers as well, and brings them back when the selection is
cleared.

The Word Inspector shows the pronunciation and syllable count straight away and
a "Finding rhymes…" indicator while the first rhyme search of a session runs,
instead of saying there are no rhymes until the search finishes.

## Pending iOS draft safety during backup and restore

Text typed while a Google Drive backup or restore is running is now also
written to a small recovery file as each edit is made. If that file cannot be
written, the editor shows "Save failed" with Retry instead of the saving
indicator, because that edit would not survive a kill. A backup or restore
does not start when the open song has an unsaved edit whose recovery file
cannot be written; the edit is saved to the library and the backup status says
why. If the app is closed or
killed before the operation finishes, the next launch puts that text back. With
iCloud sync on, it always comes back as a separate song, because another
device's newer version of the original may not have arrived yet. With a
local-only library it goes into the same song when that song is unchanged, and
otherwise into a separate song, so neither version is lost. A separate song
gets the recordings the original had when the operation began. Another song
that happens to have the same text does not count as the text having been
saved. If the recovery cannot be saved, the copy and its recordings are kept
and tried again on later launches; it is not recovered into the temporary
library used when the real one cannot be opened, and a copy that cannot be read
is set aside rather than deleted.

The backup that starts when the app goes to the background now asks iOS for
extra run time. Trying to delete a song during a backup or restore now says, in
the song list, that it can be deleted once the operation finishes.

Recording copies left behind by a killed operation are removed at the next
launch only when identical recordings (same name and content) still exist in
the library; otherwise they
stay on the device and are not shown in the app. Covered by unit tests that
drop the editor mid-operation; a real kill on a device has not been tried.

## Pending Android backup format

Android writes Google Drive backups in the same v3/RAI3 format as iOS and still
reads the two earlier formats, so a backup last written by iOS no longer shows
as unreadable on Android. Older Android builds cannot read a backup once a newer
build has written it. A shared test vector is checked on both platforms; a live
exchange between an Android and an iOS device has not been verified.

## Pending Android large-recording sync

One recording over 16 MiB no longer stops Google Drive sync on Android. Such a
recording stays on the device that holds it and is skipped by Android: it is
not uploaded, not downloaded, and not listed in the backup unless another
device already uploaded it, in which case its entry is kept unchanged. The sync
status says how many recordings were skipped as too large.
Covered by JVM tests only; not verified on a device or against an iOS backup.

## Pending Android large-library recording sync

Google Drive sync on Android no longer fails with "Recording transfer exceeds
the allowed size" once a library's recordings total more than 64 MiB. The
backup may list any total; recordings upload one at a time, and a device
restores them in groups of at most 64 MiB, each saved before the next starts.
Free space for the whole restore is checked first. If a restore is interrupted,
the groups already saved are kept and the next sync fetches only what is still
missing. The 16 MiB per-recording limit is unchanged. Covered by JVM tests
only; a restore of a library over 64 MiB has not been run on a device.

## Pending release-tooling safety

Release scripts require explicit empty emulator targets, preserve existing app
data and outputs, verify a trusted Android signer, and scan decompressed release
content. Runtime-key checks avoid host argv and diagnostic disclosure. Sign-off
reports remain incomplete diagnostics until candidate-bound external evidence is
reviewed. Fixture tests verify orchestration only; they do not establish device,
provider, signing, or store acceptance.

## Writers Block for iOS 1.0 (6) — TestFlight candidate

This candidate combines the current iOS repairs for TestFlight acceptance.
App Store Connect processing and tester availability establish distribution
status; a successful archive alone does not. Android release status is tracked
separately.

### Changes to try

- Approve cloud AI sharing separately for selected context and the whole song.
  Changing provider or expanding the shared scope requires the matching consent.
- Choose Perfect, Near, or Slant rhymes. Suggestions must match the selected tier;
  an unmatched response shows a no-match message instead of unrelated filler.
- Use a local GGUF model for writing and synonym suggestions. Saved custom model
  selections persist across relaunches. Gemma 4 and legacy Gemma models use the
  matching chat format from model metadata; unsupported formats show an error.
- Undo and redo edits, select text containing emoji, and switch songs while an
  autosave or rewrite is pending. These paths preserve the intended song and
  selection.
- Try the appearances on iPhone and iPad, including large text, the keyboard,
  rewrite controls, and the iPad projects sidebar.
- The Ink Marks analysis style and its Settings selector are removed on iOS; rhyme and syllable analysis is shown in colour.
- Restore or remove trashed songs and recordings. Recording cleanup rejects paths
  outside its storage directory; backup and sync validate restored metadata and
  keep provider API keys in the Keychain.

### Validation status

Release approval requires SHA-bound evidence on the pull request: exact source and
installed executable hashes, full native unit/UI results, phone/iPad captures,
real local-model outputs, signing checks, and App Store Connect processing.
Credential-dependent cloud tests require the corresponding provider keys.

Simulator inference uses the CPU backend after a controlled comparison found
corrupted Gemma 4 output on the simulator Metal device. Physical devices retain
Metal acceleration; physical-device model performance remains a separate check.
Live two-device CloudKit sync requires signed-in devices and remains unverified.

## Historical Writers Block / RhymeAI 0.2 Readiness Draft

The following historical draft predates the iOS 1.0 (6) candidate. Its command
results and remaining-work list do not describe current candidate acceptance.

## Highlights

- Native Android and iOS songwriting surfaces remain enabled: Gemini, OpenAI,
  Claude, Local provider selection, project persistence, trash, export, rhyme
  context, syllable, stress, and IPA previews.
- Gemini live paths are verified for suggestion, rewrite, streaming, cancellation,
  invalid-key handling, blocked responses, and offline/timeout failure messaging.
- Android release builds are minified, can be signed through ignored
  `android/keystore.properties`, and have a release smoke gate for signing,
  release artifact key scanning, install, and launch.
- Android Release visual audit captures and reviews phone and tablet
  light/dark/large-font launch screenshots plus populated editor, assistant, and
  export surfaces.
- iOS Release builds have a signed simulator build/launch smoke gate, archive
  creation, and release binary key scanning.
- iOS Release visual audit captures and reviews light/dark iPhone and iPad
  simulator screenshots.
- iOS Release visual walkthrough captures and reviews welcome, populated editor,
  export sheet, assistant panel, no-key assistant error, and no-key rewrite error
  screenshots.
- Cross-platform UI polish keeps Android Material and iOS Liquid Glass surfaces
  consistent with the shipped design tokens, including recordings search,
  transient error feedback, motion timing, and warning color treatment.
- Android local GGUF inference has a dedicated emulator/device smoke gate with
  passing evidence from a real ignored GGUF fixture.
- OpenAI and Claude happy paths have a BYO-key cross-platform provider smoke
  gate for suggestions, rewrites, and streaming.
- iOS CloudKit readiness has a scriptable static gate and a live two-device
  checklist for final sync verification.
- The latest final sign-off command evidence is recorded in
  `docs/FINAL_SIGNOFF_STATUS.md`.

## Verification Commands

```sh
./scripts/verify.sh
./scripts/final-signoff-status.sh
./scripts/android-release-smoke.sh
./scripts/android-release-walkthrough.sh
./scripts/android-release-live-gemini.sh
./scripts/android-release-visual-audit.sh
./scripts/ios-release-smoke.sh
./scripts/ios-release-walkthrough.sh
./scripts/ios-release-visual-walkthrough.sh
./scripts/ios-release-visual-audit.sh
./scripts/ios-cloudkit-readiness.sh
./scripts/ios-local-provider-smoke.sh
./scripts/provider-live-smoke.sh # requires exported OPENAI_TEST_KEY and CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY
LOCAL_GGUF_PATH=/absolute/path/to/model.gguf ./scripts/android-local-model-smoke.sh
```

## Remaining Before Final Sign-Off

- Run CloudKit live two-simulator/device matrix with an iCloud account.
- Run `scripts/provider-live-smoke.sh` with supplied OpenAI and Claude keys.
