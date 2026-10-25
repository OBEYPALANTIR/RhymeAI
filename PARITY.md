# Parity Matrix

This tracks behavior that must stay aligned between Android and iOS.

## Provider and key handling

- Android: API keys are read on demand through `MainViewModel.apiKey(provider)`. Debug builds may fall back to `BuildConfig.GEMINI_TEST_KEY` for Gemini only when the secure store is blank.
- iOS: API keys are read on demand through `EditorViewModel.apiKey(for:)`. Debug builds may fall back to `GEMINI_TEST_KEY` for Gemini only when the Keychain is blank; UI tests can seed the existing in-memory keychain seam from the same environment variable.
- Parity status: Aligned for debug-only Gemini test-key fallback. Release builds keep the fallback empty or compiled out.
- Provider/model list parity: Android and iOS both list the same Gemini, OpenAI, Claude, and local model IDs in provider-picker order. OpenAI/Claude happy paths are scriptable through `scripts/provider-live-smoke.sh` when BYO keys are supplied.

## Gemini live checks

- Gemini live suggestion and rewrite flow: Verified on Android with `GeminiSdkLiveGateTest`; verified on iOS with `Writers Block Gemini Live` user scheme and `Writers_BlockTests.geminiSuggestionRewriteAndStreamingPathsWorkWithDebugKey`.
- Gemini rewrite actions: `REPHRASE` / `rephrase`, `HARDER_RHYME` / `harderRhyme`, and `PUNCH_UP` / `punchUp` are live-verified on both platforms.
- Gemini streaming: Verified on Android and iOS through the same live tests.
- Gemini service-level stream cancellation: Live-verified on Android and iOS by cancelling the Gemini suggestion stream after the first emitted suggestion.
- Gemini Android UI cancel behavior: Instrumented UI-verified that the assistant button changes from `Suggest Next Line` to `Stop`, cancels the in-flight suggestion request, and returns to `Suggest Next Line`.
- Gemini iOS UI cancel behavior: Simulator UI-verified that the assistant button changes from `Suggest Next Line` to `Stop`, cancels the in-flight suggestion request, and returns to `Suggest Next Line`.
- Gemini invalid-key failure: Verified on Android and iOS; failures use user-facing messages and do not echo the invalid key.
- Gemini timeout/offline and blocked-response failures: Unit-verified on Android and iOS; Android emulator offline and iOS simulator unreachable-endpoint UI smokes verify timeout/offline failures use the shared connection retry message and return to `Suggest Next Line`; blocked/safety responses use the shared blocked-response message.
- Gemini suggestion response parsing: Aligned for line responses, JSON arrays, JSON object array wrappers, numbering/bullets, duplicate suggestions, prompt echo, provider markers, and overlong lines.
- Gemini prompt shaping: Unit-verified on both platforms for immediate vs whole-song context, target-rhyme vs new-rhyme instructions, section hints, complexity, six-line output contract, and every rewrite action instruction.
- Rewrite action UI walkthrough: Android instrumented and iOS simulator UI-verified that `Rephrase`, `Harder Rhyme`, and `Punch Up` each open the inline rewrite review controls and that `Cancel` returns to the rewrite chip bar.
- Gemini empty suggestion stream: Android and iOS both surface `AI did not return suggestions. Try again.` instead of leaving a blank result.
- Gemini no-key and provider status failures: Unit-verified on both platforms for suggestions, streaming, rewrite, synonyms, rejected-key, missing-model, rate-limit, and service-error user messages before provider bodies can leak into UI text.

## Export checks

- TXT export: Android and iOS unit-verified for untitled fallback, optional theme header, and lyric text preservation.
- LRC export: Android and iOS unit-verified for shared metadata headers, blank-line handling, leading lyric indentation preservation, and trailing horizontal whitespace trimming.
- JSON export: Android and iOS unit-verified for project field round trip. Platform timestamp encodings differ by model type (`Long` on Android, ISO-8601 `Date` on iOS), but each export remains re-importable on its source platform.
- PDF export: iOS unit-verified to produce PDF bytes from a long lyric sheet. Android instrumented-verified that a long lyric sheet produces readable PDF bytes, paginates through `PdfRenderer`, and renders visible ink on the first page. Both advance the layout cursor by every wrapped theme row, so lyrics start below a long theme (iOS by the theme's measured height; Android per row with page breaks, instrumented `pdfExportStartsLyricsBelowAWrappedTheme`).

## Trash and persistence checks

- Android sync merge: Unit-verified that active project changes merge by `updatedAt`, trash entries merge by `deletedAt`, newer trash removes stale active copies, and newer restored active projects are not deleted by stale trash entries.
- Recording deletions through Drive sync: both platforms write an id tombstone (`recordingId`, with the display name as `fileName` for display) when a trashed recording is permanently deleted or expires from Trash (iOS `EditorViewModel.upsertPermanentDeletion`, Android `ProjectRepository.recordRecordingDeletion` via `VoiceMemoService.recordingDeletionRecorder`), written before the file is removed. Android also skips restoring a remote recording that sits in its local Trash (`RecordingSyncPlanner.planRestores(locallyTrashed)`). A recording whose winning id tombstone arrives through Restore or Import moves to quarantine on both platforms (Android `voice-memos-quarantine/`, iOS `recording-quarantine/`; A28) and is never deleted; neither platform has a recovery UI for quarantine yet.
- iOS trash lifecycle and CloudKit readiness: In-memory SwiftData unit-verified that moving the current project to trash clears editor state, creates a 30-day trash entry, collapses duplicate trash rows with the same ID, restore collapses duplicate active/trash rows with the same ID, and purge removes only expired trash. `scripts/ios-cloudkit-readiness.sh` verifies the private CloudKit container, entitlements, remote-notification background mode, build output, and trash conflict tests before live sync.
- Import/autosave persistence: Android instrumented-verified that imported projects and debounced autosaves persist projects, current project ID, and editor state through DataStore and restore through a fresh ViewModel. iOS in-memory SwiftData unit-verified that imported projects and debounced autosaves persist the expected project fields and select the imported/saved project for editing.

- Song Notebook selection: opening the notebook keeps the editor's selection, so "Keep selected lyrics" is enabled for it on both platforms (iOS `SongNotebookView` retains and offers it; Android skips the modal selection clear for the notebook, instrumented `openingTheNotebookKeepsTheSelectionForKeepSelectedLyrics`).

## Prosody checks

- Android and iOS unit-verified shared dictionary stress counting, IPA stress markers, fallback syllable counts, punctuation/digit normalization, internal apostrophe retention, CMU rhyme keys, multi-pronunciation rhyme keys, stopword filtering, and short unknown-word rhyme suppression. Typographic (U+2019) and modifier-letter (U+02BC) apostrophes read as the straight apostrophe wherever words are split or looked up, so "we’re" is the one dictionary word "we're": Android `LyricTokenizer.APOSTROPHES` / `ProsodyAnalyzer.normalizeWord` (unit `curlyApostrophesReadAsStraightOnes`) and the eval's `scoring.WORD_PATTERN` / `normalize_word` (`test_curly_apostrophes_normalize_like_the_apps`). Known difference at this head: iOS `LyricRegex.word` and `ProsodyAnalyzer.normalizeWord` still split a curly contraction (only `LyricRegex.lastWord` keeps U+2019); the parallel iOS fix (bug-hunt finding #7) removes it. Single-word rewrite validation (`isKnownSingleWord`) is unchanged: it still requires the exact dictionary spelling.
- Near and Slant next-line end-word lists: Android and iOS unit-verified (`NearSlantCandidateListTest(s)`) against the bundled dictionary and frequency list for chair, would, night, home, river, and alone. Both build them with the same tail classifier (`ProsodyAnalyzer.tailRelation`): Near is the same stressed vowel with a same-family consonant swap, one added or dropped consonant, an extra unstressed syllable, or shifted stress; Slant is consonance (identical coda, different vowel) or assonance (same vowel and syllable shape, unrelated consonants); a vowel before R counts as its own vowel. Each word takes its closest relation over every target x candidate pronunciation (Perfect > Near > Slant), the same rule `rhymeRelation` uses, so every listed word verifies as its list's relation (unit-verified for 14 multi-pronunciation anchors such as abuse, read, live, close, lead). Lists rank content words before function words, never include the anchor or its inflections, and return fewer words rather than padding. Returned suggestion lines go through the same filter on both platforms (`RhymeLineFilter`): the streaming path admits only the requested relation (tier 2 perfect, 1 near, 3 slant) in arrival order, never pads with misses, and reports "none matched the requested … rhyme" when every returned line misses; a chorus-hook ending only changes the badge. Unit-verified on Android in `SuggestionRhymeFilterTest` (filter) and `RhymeConstraintTest` (tiers), and on iOS in `RhymeConstraintTests` and `LocalGenerationBoundaryTests`.
- Curly (U+2019) and modifier-letter (U+02BC) apostrophes inside a word are the straight apostrophe on both platforms: the word tokenizers (Android `LyricTokenizer`, iOS `LyricRegex`) keep them in the word and `ProsodyAnalyzer.normalizeWord` folds them before the dictionary lookup, so `we’re` and `we're` count the same syllables. The shared fixtures contain no curly apostrophes. iOS unit-verified in `Writers_BlockTests.prosodyAnalyzerTreatsCurlyApostrophesAsStraightOnes`; the Android side lands in its own PR.

## Local model checks

- A finished model download installs the model but only takes over the provider and model selection when the user has not asked for another provider or model since it started, counted as soon as the choice is made rather than when its validation lands (Android `modelChoiceRevision` / `useDownloadedGemma(choiceRevisionAtStart)`, instrumented `GemmaDownloadSelectionInstrumentedTest`). Tapping "Use" on an installed download always selects it. Known difference at this head: iOS `GGUFDownloadManager` still selects a completed download unconditionally; the parallel iOS fix (bug-hunt finding #5) removes it.
- Android Gemma GGUF download helpers are unit-verified for missing, incomplete, non-GGUF, valid GGUF, resumable partial download, HTTP failure, no-storage messaging, and progress formatting.
- Android local provider/model handling is unit-verified: the Local picker exposes only `local-model`, and suggestions, streaming, rewrites, and synonyms surface the shared no-model-loaded message without requiring an API key. A live `LocalModelInstrumentedTest` gate is wired through `scripts/android-local-model-smoke.sh` and passed on `emulator-5554` with an ignored TinyLlama Q2 GGUF fixture.
- iOS local provider/model switching is unit-verified: the Local picker exposes only `local-model`, selecting Local moves the current model to the on-device model, and Local does not require an API key.
- Resilient local suggestions: on both apps the on-device path (Android `validatedLocalSuggestionStream`; iOS `emitLocalLines`) no longer requires exactly six lines. After sanitize and the strict `RhymeLineFilter` (never padded with non-rhyming lines), fewer than six survivors retries the generation once (each local generate call draws a fresh seed: Android `LocalModelService` seed -1, iOS `GGUFModelService` random seed) and merges the retry's survivors, deduped by the suggestion key, after the first attempt's survivors up to six. Three to five survivors are shown as the suggestions with no error; fewer than three after the retry raises the existing incomplete / no-matching-rhymes error, and more than six are capped at six. Each generation gets its own raw-line budget (twelve accepted candidates when constrained); only dedupe keys and the shown count carry into the retry. A retry that throws (timeout, generation error, leaked markup) is treated like an empty retry when the first attempt already has three survivors; with fewer, its error surfaces. Cancellation always propagates. Unit-verified on both platforms for 6 survive (no retry), 4 survive + retry merges to 6, 4 survive + empty retry shows 4, 4 survive + failed retry shows 4, 2 survive + failed retry surfaces its error, and 2 survive after retry fails (`LocalSuggestionRetryTest`, `LocalGenerationBoundaryTests`).
- Resuming a paused catalog download credits the bytes already received (Android from the partial file in `GemmaDownloads`, iOS from `NSURLSessionResumeBytesReceived` in the saved resume blob, read by `GGUFModelStorage.receivedBytes(inResumeData:)` from the keyed archive URLSession writes or a plain property list), so only the remainder plus the reserve must be free. iOS unit-verified in `GGUFDownloadCatalogTests.resumeSpaceCheckCreditsTheBytesAlreadyDownloaded` and `receivedBytesAreReadFromKeyedArchiveAndPlainPlistResumeData`.
- A finished catalog download selects itself only while the user has not chosen another model or engine since it began: both platforms keep an in-process choice revision (Android `modelChoiceRevision`, iOS `GGUFDownloadManager.modelChoiceRevision`) that every explicit model, custom-model or engine choice bumps, snapshot it when the download starts, and select on completion only if the snapshot still matches; otherwise the file is installed and the status reads `<title> downloaded.` (or `verified.`) and the user taps Use. Known difference: a completion with no live snapshot (Android's explicit Use of an already-complete file) selects on Android, while on iOS a download the system finishes for a manager that did not start it (restored after a relaunch) installs without selecting. iOS unit-verified through the manager in `GGUFDownloadCompletionTests`.
- Memory gate for E4B: both platforms treat E4B as needing at least 10 GiB of total RAM (Android `RAM_THRESHOLD_E4B_BYTES` / `gemmaModelNeedsMoreMemory`, iOS `GGUFDownloadCatalog.ramThresholdE4BBytes` / `needsMoreMemory` on `ProcessInfo.processInfo.physicalMemory`) and show the same warning, "May be slow on this device — needs more memory", when the user downloads or chooses it on a smaller device; downloading stays allowed. Known difference: iOS also keeps a finished E4B download installed but unselected on such a device (`GGUFDownloadManager.finish`, unit-verified in `GGUFDownloadCompletionTests`), while Android still takes it up on completion.
- Deleting an installed catalog model from Settings (Android `MainViewModel.deleteDownloadedGemma` / `deleteInstalledGemma`; iOS pending its companion PR): every row whose catalog file exists on disk, including a stale version that fails the size or SHA-256 check, shows a destructive Delete action that is disabled (not hidden) while that entry downloads, the local model is loading, or a local suggestion, rewrite or synonym request is in flight. A confirmation ("Delete <model>?" / "Frees <size on disk> on this device. You can download it again later.") precedes removal of the installed file, the partial download and its resume state; the saved-model entry and the verified-artifact marker go with them, and the row offers Download again. Every delete queues on the loader's `LocalModelOperationGate` mutex and runs non-cancellably, and while it runs (`gemmaDeletingModel`) that entry's download, use and select are refused and the local-model actions are disabled; a download whose integrity check ran across a delete of the same entry does not publish its selection, and saved-list and selection writes share one lock (a registration writes its selection only while it is still the selection), so an older queued write cannot restore a deleted entry or its selection; a failed download attempt refreshes the rows from disk. Deleting the selected model unloads it first, bumps the choice revision so a download finishing later does not re-select on its own, persists an explicit none that the next launch honours (no fallback to the first remaining model), and only then clears the selection, without choosing another model, so a failed step leaves a retry able to do both again; the assistant stays in its choose-a-local-model state. Bookkeeping follows the disk even after a partial failure, and a failed delete or persistence write reports inline on the download error row. Android unit-verified (`GemmaDownloadsTest`) and instrumented (`GemmaDeleteInstrumentedTest`, `SettingsModelDeleteUiTest`, `ModelDeleteUiTest`).

## Next-line suggestion prompt

- Whole Song Context defaults on: an unset preference reads as on and an explicitly saved off is kept (iOS `editor.useWholeSongContext` in UserDefaults, Android `editor_use_whole_song_context` in DataStore via `ProjectRepository.DEFAULT_USE_WHOLE_SONG_CONTEXT`). Because cloud sharing follows this setting, a first cloud suggestion now asks for whole-song consent. Unit-verified on both platforms (`SuggestionPromptGuidanceTests` / `EditorTogglePersistenceTest`).
- Complexity wording is byte-identical (`RhymeComplexity.promptHint`, `finetune/eval/prompts.py` `RHYME_COMPLEXITIES`) and reaches both the on-device and cloud prompts. Simple and Complex carry numeric, checkable targets; only Complex asks for wordplay: Simple "Each line must be 4 to 7 plain, everyday words. Prefer one-syllable end words. No wordplay."; Moderate (default) "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever."; Complex "Each line must be 8 to 12 words. End each line on a word of two or more syllables, or put an internal rhyme inside the line. Use vivid, specific, less common words and double meanings."
- The allowed end-word list is level-aware (`RhymeConstraint.candidateEndWords(..., complexity)` via `levelEndWords` on both apps, `scoring.candidate_end_words(..., complexity=)` via `level_end_words` in the eval): the relation's frequency-ranked candidates are, at Complex, stably partitioned so words of two or more syllables come first; at Simple, reduced to one-syllable words unless fewer than six exist, when the remaining words follow in their original order; at Moderate (the default for every caller that does not pass a level) left exactly as before. Syllables come from each platform's `ProsodyAnalyzer.analyzeWord` / `syllable_count_word` with the same dictionary. The level reaches the list on every suggestion path: Android `suggestionRhymeConstraint(..., complexity)` from `streamSuggestions` and the cloud prompt's own rebuild without whole-song context; iOS `rhymeConstraintBlock`/`rhymeConstraintWords(..., complexity:)` from `buildPrompt` and `buildLocalPrompt`; the eval's `run_eval.prepare_case`. The shared fixture `shared/fixtures/complexity-end-words-v1.json` (11 anchors x 3 relations x 3 levels, produced by `finetune/eval/complexity_end_words_fixture.py`) pins Android and the eval word for word; iOS asserts the Perfect level rule on its bundled dictionary (no Near/Slant fixture test there). The eval's `scoring.find_rhymes` / `rhyme_relation` port the apps' exclusive perfect/near/slant pools and `rhymeRelation` (every pronunciation pair, songwriter order), so `ordered_candidates` draws Near and Slant from the relation's own pool and `rhyme_tier` returns 3 for slant, as the apps do. Simple only prefers one-syllable endings because its list falls back to longer words (anchors such as "arrival" and "river" have no one-syllable rhyme; "love" and "world" have four and five, under the six distinct endings the on-device rule asks for) and because chorus hook words are never filtered by the level. Chorus repeat (2nd+): Android and the eval put first-chorus end words that stand in the requested rhyme relation to the target first, verifying the relation directly (`ProsodyAnalyzer.rhymeRelation` on Android, `scoring.rhyme_relation` in the eval) rather than by membership in the 12-word list, then cut the merged list back to 12, so a hook the Complex or Simple ordering pushed past the cut is still promoted; iOS prepends every first-chorus end word unfiltered (pre-existing difference, unchanged). Neither reapplies the level after the merge, so hooks stay in front at every level.
- On-device prompt guidance is byte-identical: after the rhyme hint and constraint block comes "The writer is stuck on the next line and wants ideas to pick from, not a finished verse.", and the Rules list (after "Return only candidate lyric lines.") adds six-different-directions, "End each line on a different word from the allowed list." when the list has at least six distinct words (case-folded, so a later chorus that lists its hook word several times counts it once), "The allowed list has fewer than six words, so end words may repeat, but the six lines must still be six different ideas." when it has one to five, and "End each line on a different word." when no list is sent (`localEndWordRule`; unit-verified for 3- and 6-word lists and for repeated chorus end words), the raw-material/own-voice rule, the do-not-resolve rule and the stay-inside-the-song rule. The six-line count, format rules and parsers are unchanged. Cloud prompts are prose without a Rules list and ask for 12 candidates, so they only pick up the complexity wording. `finetune/eval/prompts.py` mirrors the Android builder.
- Context & Theme is independent of Whole Song Context: the field stays editable in both modes, and a non-empty theme is sent in every suggestion prompt (on-device "Theme: …", cloud "theme/context: …"), together with the full lyric when Whole Song Context is on. Only an empty theme falls back to "Infer from the lyrics." (on-device) or, in the cloud prompt, "Whole song context enabled; infer the theme from the full lyrics." / "No specific theme provided". The coupling came from `7fc6552` ("Keep context box fixed"), which disabled the field and replaced the theme whenever Whole Song Context was on; it was not a consent rule. Cloud consent is unchanged: the scope follows Whole Song Context only, and both scopes' disclosures already list the theme. Unit-verified on both (`themeIsSentWithWholeSongContext`). Because the field stays editable while a request runs, any theme change cancels in-flight AI work (suggestions, rewrite, synonyms, a pending consent prompt) and clears the shown suggestions and error, so results for the previous theme never land: Android `onThemeChanged` → `cancelEditorAIWork` (instrumented `changedContextRejectsLateResultsAndCancelsActiveWork`), iOS `theme.didSet` → `cancelEditorAIWork` (unit `themeEditDropsInFlightSuggestionsWithWholeSongContextOn`).
- On-device lyric window (Android `AIService.localLyricWindow` via `localLyricsContext`, iOS `AIService.localLyricWindow`, Python `local_lyric_window`), budget 3,100 UTF-16 units with Whole Song Context on (900 of them for the song's opening), and on Android only 2,600 with it off (no opening). Lyrics within the budget after whitespace trimming are sent as is. Longer lyrics are split on "\n" and keep, in order: (1) the cursor's blank-line-delimited stanza (the same block `NextLinePlacement` uses, ending at the cursor when the cursor line is blank) plus the lines directly above and below the cursor; (2) the song's opening lines up to the opening allowance; (3) the lines nearest that window, one above then one below, while they fit. Room for two marker lines is reserved, so the result never exceeds the budget. Each skipped run that contains a lyric becomes one "[Lyrics trimmed for on-device speed]" line; the result is whitespace-trimmed. If the stanza alone is over the budget, only the cursor's neighbours are pinned and the nearest-line fill takes the rest of the stanza; if the neighbours are still over, only the cursor line is pinned. A cursor line longer than the budget keeps its end (where the next line is inserted) after a marker, cut on UTF-16 units and never starting on a low surrogate, so the output never exceeds the budget (unit-verified on both by sweeping every cursor line of every fixture song). The cursor line is `NextLinePlacement.cursorLineIndex` (no cursor means the last line). Byte-identical output is proven by the shared fixture `shared/fixtures/local-lyric-window-v1.json` (a 300-line song with the cursor at the start, a middle lyric line, a middle blank line, the end and no cursor; a single 4,000-character line; a 3-line stanza whose middle line is 4,000 characters with the cursor on each line; and a line of 2,000 non-BMP emoji (4,000 UTF-16 units); expected values produced by `finetune/eval/prompts.py`, which also counts and cuts in UTF-16 units): Android checks all 22 cases, iOS the 11 whole-song cases from a bundled copy (`Writers Block/Writers BlockTests/local-lyric-window-v1.json`, which the simulator can read and the Android test checks is byte-identical to the shared file), and both check that the built prompt carries the window for the cursor.
- Known differences: with Whole Song Context off, iOS sends the cursor's stanza untrimmed (pinned by `localPromptRetainsLongStanzaAndWholeSongPolicy`), while Android sends the whole lyric through the window above. Android rewrites also use the 2,600 window with the cursor at the last line. The on-device rhyme hint and whole-song instruction wording still differ between platforms.

- A running suggestion request survives the first autosave of a new song: the save only gives the draft its ID, so Android's context check treats a request captured with no project ID as current once that ID exists (`isCurrentAIContext`, instrumented `firstAutosaveOfANewSongKeepsTheRunningRequest`); iOS accommodates the first save through request IDs. Opening another song still invalidates through the revision counters.

## Rhyme context checks

- Android and iOS unit-verified that section headers do not consume rhyme-scheme positions, latest previous lyric lines with the same scheme letter become the rhyme target, current section detection reaches prompt shaping, and empty lyrics use the first active scheme letter. Android pure seam additionally verifies cursor clamping and empty-scheme fallback to `A`.
- Rhyme-scheme display row accounting follows Android `RhymeSchemeDisplay.kt` (`rhymeSchemeRows` at #55 candidate `5d401dff`): section headers and non-current blank/whitespace rows show no letter and consume no scheme position; the current blank shows `currentLetter` without consuming one; lyric rows advance and wrap through the scheme. iOS source/host verification is tracked in the G6 handoff; simulator/UI parity remains unverified.
- `RhymeConstraint.lineEndWord` takes the last lexical word on both platforms (Android `wordPattern`, iOS `LyricRegex.word`), so an unspaced dash or hyphen (`day—night`, `day-night`) still ends on `night` instead of a word the dictionary cannot know. Known difference: iOS skips a trailing match that is only apostrophes (a closing quote, `carry me home '` ends on `home`); Android's `lastOrNull` returns the empty word there. iOS unit-verified in `RhymeConstraintTests.lineEndWordStripsPunctuationAndQuotes`.

## Cloud backup parity checks

Backup v4 is specified for both platforms; the Android side is implemented and
tested here. The iOS side is pending the companion PR, so every iOS statement
below is the contract it must meet, not verified behaviour.

- Backup format (v4): Drive `appDataFolder` holds the plain manifest
  `rhymeai-manifest.json` and one raw file `rec_<recordingId>` per recording,
  uploaded with `appProperties` `id`, `projectId`, `fileName`, `sha256` and
  `bytes` (Android omits a property whose key plus value exceeds Drive's 124-byte
  limit; the manifest stays authoritative). Manifest keys: `version` (4),
  `savedAt` (ISO-8601 UTC with milliseconds, `2026-10-22T21:00:05.123Z`),
  `savedByClientId`, `platform`, `projects`, `trashed` (project fields plus
  `trashedAt`), `recordings` (`id`, `projectId`, `fileName`, `bytes`, `sha256`,
  `uploadedAt`), `deletions` and `manifestSha256`. A recording's `fileName` is
  its display name (A36). A37 adds optional booleans, written only when true:
  `precedenceRepaired` on a song, a Trash entry's song or a recording (its
  `updatedAt` or `uploadedAt` is a first-seen repair) and `trashedAtRepaired` on
  a Trash entry; a manifest without repairs is byte-identical to one written
  before the flags existed. Every precedence time
  (`updatedAt`, `trashedAt`, `uploadedAt`, `deletedAt`) is an integer of epoch
  milliseconds; nothing is floored (A23). A song tombstone is `{projectId,
  fileName: null, deletedAt}`; a recording tombstone adds `recordingId` beside
  `fileName` (kept for display); a pre-v4 name-only recording tombstone has no
  `recordingId` and applies by project and file name. No passphrase, no
  client-side encryption; API keys never enter the manifest.
- Canonical form and hash: `manifestSha256` is the SHA-256 of the object
  without that key, serialised with keys sorted by Unicode code point, arrays
  in stored order, no whitespace, UTF-8, integers only, and escapes limited to
  `\"`, `\\`, `\n`, `\r`, `\t` and lowercase `\u00xx` for other control
  characters (non-ASCII is not escaped). The uploaded file may be pretty-printed.
  Readers refuse a hash mismatch ("Backup file is damaged; it was not merged.")
  and any `version` above 4, and never overwrite such a file. Pinned by
  `shared/fixtures/sync-manifest-v4.json` (`scripts/generate-sync-manifest-v4-fixture.py`,
  stdlib only, `--check`; its sample uses non-zero milliseconds in every
  precedence time); iOS reads the copy at
  `Writers Block/Writers BlockTests/sync-manifest-v4.json`, and Android
  `BackupManifestTest` fails if it drifts (it skips while the copy is absent).
- Recording identity (A21): every recording has a stable lowercase UUID, given
  when it is recorded, imported from audio, restored, imported from an archive
  or first seen. A pre-v4 entry's id is the name-based UUID (version 3, MD5) of
  `rhymeai-legacy-recording:<projectId>/<fileName>/<sha256>`, so every device
  derives the same one. Merge, tombstones, presence checks, restores and
  imports key on the id: a rename changes only the display name; a live and a
  Trash recording with the same name are two recordings with two records; two
  recordings may share a display name and nothing is renamed or replaced;
  byte-identical audio imported again after a deletion is a new recording with a
  new id and time, and the old id's tombstone still applies only to the old id.
- Stored precedence time (A20): each device keeps a record per recording id in
  DataStore beside the songs (`displayName`, `uploadedAt`, `sha256`, `bytes`,
  origin recorded/restored/imported/migrated, and where its bytes are now, live
  or in Trash). It is written when a take is recorded or imported from audio
  (that moment), restored or imported from an archive (the entry's own
  `uploadedAt`), and kept through renames, Trash and restore from Trash. A file
  with no record at its path, or whose bytes no longer match the record there,
  is a recording seen for the first time: it gets the derived pre-v4 id and is
  stamped once with its file time. Random ids are given only to new recordings
  and audio imports. Files sharing one pre-v4 identity (project, name and hash,
  such as a live copy and a Trash copy) are one recording with that one id on
  every device (A26). Each snapshot chooses one canonical copy among all copies
  present, recorded or new: a live copy, else the most recently trashed, then by
  path, so the choice does not depend on arrival order; it moves the record (id
  and time) to that copy, and the other copies move to `voice-memos-quarantine/`,
  which is never listed, adopted, backed up or deleted. An adopted file's time is
  the earliest file time among its copies seen for the first time (origin
  `adopted`); once stamped, a recording's time never follows a file time again,
  and a recorded, restored or imported recording keeps its stored time. Adoption is all or
  nothing: folders are listed and every entry's attributes read with calls that
  throw, so an unreadable file, an unlistable folder or a folder whose entries
  cannot be examined fails it, and Delete Forever, Trash expiry, Restore and
  Import that depend on it fail with nothing changed. Only confirmed absence counts
  as absence: reconciling an interrupted move, or dropping a record whose file is
  gone, throws on a file that cannot be examined and commits nothing, and records
  of songs outside a scan are kept unexamined. A backup (and an export) moves no
  file (A17). Its local writes are metadata (and the recovery store's kept songs): record stamping, finishing or
  undoing an interrupted move (reconciliation), the A32/A37 precedence repairs,
  and, after a verified manifest write, each held recording's display name as
  written (clearing a rename that was written). A duplicate copy stays where it
  is until launch, Restore or Import quarantines it, and a file still awaiting
  its A36 name is left out and counted ("N recordings still have their old file
  names and were left out…"; Export counts those in songs and in the Trash Bin:
  "N recordings with an old file name left out", and always adds that Trash Bin
  recordings, takes waiting to be saved and recordings set aside are never
  exported). It writes nothing to the file system: a claim left by an
  interrupted move stays, with its intent pending, until launch, Restore or
  Import reconciles it, and an empty file is never adopted as a recording. Rows
  without a path (from the first record store) are kept by identity until the
  scan that migrates their file, so a backup or export first loses nothing. It
  never touches restore staging.
  File times are otherwise never used as precedence.
- Local visibility (A28): after Restore or Import commits, a recording whose
  winning tombstone is now known here moves to quarantine and loses its record.
  The committed tombstones are the durable intent: if the move is interrupted or
  fails, it is retried at the next launch, Restore or Import, and until then the
  recordings and Trash lists hide every recording a known tombstone removes. The
  lists refresh when the tombstones change, playback refuses such a recording, and
  one that is playing stops. If the tombstones or records cannot be read, the
  lists show nothing and playback is refused (fails closed, A31). If the launch
  check (repair, migration, quarantine) fails, both the song's recordings and the
  Trash recordings show "could not be read" instead of an empty list, and opening
  either retries the check; when it succeeds both lists come back.
- Name-only tombstones (pre-v4): migration turns each into an id tombstone for
  the older recording it names and drops it. One that names no older entry
  removes only a recording whose id is the pre-v4 id of that name and the
  recording's own bytes, never a v4 recording that reuses the name.
- Song deletion and expiry first give every live and Trash file of the song a
  record (first-seen stamping), then commit the song's and each recording's
  tombstones in one write, a record whose file still awaits its A36 name
  included. A file left under its old name without a record of its bytes cannot
  be tombstoned, so the deletion stops (nothing changes) until migration can
  identify it.
- Empty recordings: a recording of zero bytes is refused everywhere (recording,
  audio import, manifest validation, archive import, Drive restore), and an empty
  file is never adopted as a recording.
- One id, one digest (A40), also between devices: a recording held here whose
  bytes differ from Drive's entry for its id is reported (as "not uploaded
  because Google Drive holds different audio") by Back up and Restore alike;
  Drive's entry and raw object stay, this device's audio stays, and neither is
  uploaded or downloaded over the other. Startup reconciles and adopts before its purge.
- Unfinished recordings (A22): the recorder writes into a staging folder; the
  take is moved into the song's folder, with its record, only when the recorder
  finishes it (`MediaRecorder.stop()` succeeds). A take whose stop fails is left
  unpublished and the user is told it was not saved. Snapshots never read
  staging, so a backup during recording never sees the take.
- Waiting takes (A27/A31): before recording starts, a `.take` marker with the
  take's id is written beside its staging file (if that fails, recording does not
  start); the finish and its time are recorded in it when the recorder stops, and
  a save or Retry uses that time as `uploadedAt`, never the retry time. The id in
  the marker is never replaced: a marker that cannot be read or is invalid makes
  the save fail and leaves the take waiting. A failed finish-marker write is a
  recoverable error (the take stays in staging), and a failure after the file has
  moved keeps the committed record intent. A take whose save fails stays in
  staging, survives process death and later recordings, and the song's
  recordings sheet shows "1 recording waiting to be saved" with Retry. A take
  whose finish was never recorded shows as "1 recording could not be saved";
  Retry saves it only if the recorder finalized it: its MPEG-4 index is intact,
  every sample its tables list lies inside the media data, and the extractor
  reads every sample to the end of the stream. Bytes that fail that are marked
  failed: Retry skips them, and the sheet keeps listing them ("1 recording did
  not finish") with Set aside, which moves their bytes to quarantine (kept,
  never deleted). A file that cannot be read right now stays waiting. A take
  whose marker cannot be read is never given an invented id: Retry says "A
  recording's save details can't be read, so it can't be saved yet. Its audio
  stays on this device." The `.waiting` marker of the build before take markers
  ("<id>\n<finish time>\n") is converted to a finished `.take` marker at launch.
  An import in staging carries a `<file>.import` ownership marker; one that no
  running import owns is set aside in quarantine at launch, and a staging file
  with no marker of any kind is kept and reported. A failed stop is recorded as failed. Retry finishes any interrupted
  save first and counts a take whose id is already published as saved.
- Metadata before publication (A24): restore, import, rename, move to Trash and
  restore from Trash write the record's intent (id, name, time, hash, size, new
  and old location) before the file moves, under one lock that snapshots also
  take. If the record cannot be written the operation fails and nothing moves;
  the UI says so (a finished take waits in staging, see A27). Every transition, deletion and moving snapshot (launch,
  Restore, Import) first finishes or undoes an interrupted move from its intent,
  so an interrupted move never yields a new id; a read-only snapshot (Back up,
  export) leaves an intent whose target is still an empty claim pending.
  A display name is metadata, validated as any non-empty text without NUL of at
  most 1024 UTF-8 bytes (separators, long names and names without an extension
  are allowed, A39) before its record is written; only file names, which are
  `<id>.<ext>`, are paths.
- Oversized recordings (A29): this device never lists a recording too large for
  it to move unless Drive's manifest already lists it, and then it only keeps
  that existing entry. Keeping an entry is not verifying it: the recording counts
  as backed up only when its raw Drive object is present with matching `sha256`
  and `bytes`; otherwise it is reported in the skipped count. Oversized
  recordings Drive lists that this device does not hold, live or in Trash, are
  counted once each, a Trash-held one Drive lists without its intact raw object
  counts as unpreserved, and tombstoned ones are deletions, not skips.
- Stable precedence (A32): before any merge compares or names anything, every
  song, trashed song and recording whose precedence time is missing (zero) gets
  the time this device first saw it, by identity, persisted locally
  (`first_seen_precedence_json`) and then written into the manifest; it never
  changes afterwards. Such a time is a repair (A37/A38): a tombstone, always a
  real time, beats it whatever the numbers, so an item whose time was unknown
  never outlives a deletion.
- Repair flags per time (A38): a song and a recording carry `precedenceRepaired`
  for their own time; a Trash entry carries two, `precedenceRepaired` for its
  song's `updatedAt` and `trashedAtRepaired` for its `trashedAt` (Android keeps
  them on `TrashedSongProject.project` and `TrashedSongProject.deletedAtRepaired`).
  Each comparison uses the flag of the time it compares (active versus Trash:
  the song's `updatedAt` against the Trash entry's `trashedAt`, each with its own
  flag). A tombstone is a real time: against an active song it compares with
  the song's `updatedAt`, against a Trash entry with its `trashedAt` only, and
  against a recording with its `uploadedAt`, each with its flag, so a repaired
  time always loses to a tombstone and a real one loses only to a newer
  tombstone (Android `SyncMerger.deletes`). When two Trash copies of one song
  merge, the Trash time and the song inside are settled independently, each by
  its own flag. Keys are written only when true. In a correctly hashed manifest an
  absent `updatedAt`, `trashedAt` or `uploadedAt` reads as unknown (0) and is
  repaired; a value of the wrong type is refused. A tombstone's `deletedAt`
  stays required and positive (A33).
- Repairs converge (A37): a time established that way is a repair and is marked
  (`precedenceRepaired`, `trashedAtRepaired`; Android keeps the flag on
  `SongProject`, `TrashedSongProject`, the manifest entry and the recording
  record). For one identity, a real time (an edit) beats any repair and clears
  the flag; of two repairs the smaller wins everywhere (manifest, local state and
  the first-seen map), so two replicas that repaired one time-less song at tA <
  tB both settle on tA and a tombstone between them wins. A Trash deadline is
  always recomputed from the repaired `trashedAt`, and Trash expiry repairs
  before it chooses anything (and again inside its deciding write), so a
  time-less Trash entry gets 30 days from first sight instead of expiring at once.
  A repair stays a repair through Restore, Import and export (the flag is
  published with the record). A real time from any input replaces a recording's
  local repair before anything is compared, so lists, playback and quarantine
  compare what the merge compares. Android applies this in
  `SyncMerger.supersedes` (songs, Trash, recordings and the active/Trash choice,
  where a tie keeps the Trash entry) and in `ProjectRepository.normalizePrecedence`.
- Valid tombstones first (A33): tombstones are validated where they are read
  (Android `ProjectRepository`'s deletion store runs `SyncDeletion.validate` on
  every entry; iOS validates at its store too), so a malformed one makes the
  deletion state unreadable. No adoption, reconciliation, move, quarantine or
  pending song-folder deletion happens unless that state is readable and valid,
  and the recordings lists show nothing and playback is refused otherwise.
- Recording files (A36): on disk every recording is `<recordingId>.<ext>`
  (lowercase UUID; `m4a` for the app's takes, the audio's own extension for
  imports) in the live, Trash, staging and quarantine folders, and
  `rec_<recordingId>` on Drive. The name the user sees is the record's
  `displayName`, carried as `fileName` in the manifest. A rename writes the record
  only and moves nothing, so it never stops playback. Two recordings may share a
  display name; nothing collides, nothing is allocated and no suffix is
  generated. Export is the only place a display name becomes a file name. The
  only moves are staging to live, live to and from Trash, live or Trash to
  quarantine, and the migration. Each follows the verified-transition procedure
  below (a journal or record intent with id, digest, length and claim token
  first; the target claimed with an exclusive create, because a rename would
  replace it and hard links are refused in app storage), so a file that appears
  at the target is never replaced; recovery removes only a file holding exactly
  its own claim. Journals of earlier builds (`<target>.migrate` beside a staging
  take: source, target, SHA-256, length; beside a quarantine copy: source,
  target, id, SHA-256, length) are read in full: the saved id must be the id the
  target is named by, and a journal that cannot be read in full or settled keeps
  every file in its folder where it is (reported) until it can.
  The name a backup writes for a recording it holds (live or in Trash) is its own
  when it was renamed here since its last write or Drive does not list it yet,
  otherwise the name in Drive's own entry (never one chosen by a precedence tie);
  a rename stays pending until its own name is the one written. Restore payloads
  are staged as `<id>.<ext>` too.
- Migration (A36), at every launch until done (idempotent): a file in the live
  or Trash folder not named by an id gets one, from its record at that path when
  the bytes match, else the A21 derived id, and is moved to `<id>.<ext>` in the
  same folder with its old name (a pre-A36 Trash name `<deletedAt>__<name>`
  gives the name and the Trash time) as its display name. Each move is journaled
  as a move intent, so a crash resumes from it. A file whose id name is taken by
  other bytes is left where it is and reported ("N older recording file(s) could
  not be renamed…"), and its record is kept unchanged so its identity, time and
  tombstone protection survive until the move can happen; migration deletes
  nothing. Rows written before A36 (`fileName`, claims, rename intents) are read
  as display names, and an old rename intent that never reached the file is
  undone to its old name. Waiting takes in staging move to `<id>.<ext>` with
  their markers in this order: journal, verify, move (no-replace), new marker,
  old marker removed, journal removed; a later launch finishes a journaled move
  whose target holds the journaled bytes (writing the marker from the old one)
  or redoes one whose source still does. Retry finds, inspects and marks a
  take under the recording lock, so migration cannot move it in between, and a
  take moved before its save is saved where it is now. Pre-A36 quarantine
  copies `<movedAt>__<name>` move to `<movedAt>/<id>.<ext>` through the same
  kind of journal (a kill after the claim is finished at the next launch). iOS
  performs the same migration.
- Path form (Android): records store paths relative to the canonical files
  folder, and every recording `File` (listings, records, playback, staging) is
  built on the canonical files folder (`RecordingFiles.fileAt`), because Android
  hands the app `/data/user/0/<package>`, a symlink to `/data/data/<package>`.
- Local folders (Android, under the app's files directory): `voice-memos/`
  (live), `voice-memos-trash/` (Trash time in the record), `voice-memos-staging/`
  (takes being recorded or waiting), `voice-memos-quarantine/<projectId>/<movedAt>/<id>.<ext>`
  (duplicates and deleted recordings, never deleted; a folder per move so two
  kept copies never collide).
- Take marker (Android): `<take>.take` beside the staging file, UTF-8 text with
  three lines: the recording id (lowercase UUID), the state (`recording`,
  `finished` or `failed`) and the finish time in epoch milliseconds (0 until
  finished). It is written once before recording starts and rewritten when the
  recorder stops.
- Take copy (Android): "The recording didn't finish, so it wasn't saved. Try
  recording again." (failed stop); "Couldn't save the recording. Free up storage,
  then tap Retry." (save failed, with Retry); in the recordings sheet "N
  recording(s) waiting to be saved" and "N recording(s) could not be saved" with
  Retry, and "N recording(s) did not finish" with Set aside.
- Precedence on every path (A32): Android also fixes missing times for each
  duplicate manifest before they are compared, for a conflicting read-back, for
  the restore offer's probe, and for this device's own state inside the
  transactional apply; an established time is stored in the local record, so an
  imported recording, its listing, playback and an export all use it. A v4 entry
  without `uploadedAt` reads as unknown (0) and gets its first-seen time; a
  malformed value is refused.
- Tombstone values (A33): a device always writes a positive deletion time. A
  tombstone read without one (absent, or 0) has an unknown time: it is never
  given the current time; it suspends only its own identity, on this device only
  (erratum to A33): it removes nothing (not even a repaired time), the recording
  it names is hidden and refused for playback with its bytes kept, the tombstone
  stays in this device's deletion state, and a later tombstone of the same
  identity with a valid time replaces it. It is never written anywhere shared:
  the Drive manifest and an export carry only tombstones with a valid time. Every other tombstone still applies. A negative time
  or a wrong type is malformed and makes the whole input unreadable. Duplicates of
  one identity count their newest deletion everywhere (Android collapses them at
  the store and in `SyncMerger.Tombstones`). A song tombstone has neither a
  recording id nor a file name; an id tombstone without a file name is a recording
  tombstone and never deletes a song.
- Intents and deletions (Android): undoing an interrupted move happens only when
  the bytes at the source still have the record's hash; other bytes there are
  adopted on their own and nothing is moved. Delete Forever of a recording writes
  its tombstone after adoption and deletes the bytes only if, under the recording
  lock, they are still that recording (`RecordingTransitions.deleteVerified`).
  After a song's deletion commits, its folders are cleaned under the recording
  lock (`RecordingTransitions.cleanUpDeletedSong`): every file is adopted and
  hashed, only recordings a winning tombstone removes are deleted, and any other
  bytes (a take finished after the deletion, a dropped-in file) are kept, so the
  song stays pending until they are dealt with. The decision is read under the
  repository lock and the cleanup runs outside it (lock order: recording lock,
  then repository).
  iOS stores digests in every move record (quarantine, Trash detach) and verifies
  them at replay.
- Takes of any size (Android) go through one journal: the `.take` marker (finish
  and time) and the publish intent are written before the move, Retry finishes an
  interrupted move, and a take counts as saved only when its file is in place with
  the recorded bytes.
- Ownership (Android): every move that relies on owning a file hashes it under the
  lock; size, modification time and the record row are never proof, so a
  same-length rewrite keeps its old time but not its old identity.
- Verified transitions (Android): every byte move (publish, Trash, restore from
  Trash, migration, quarantine, staging, parking and historical recovery) follows
  one procedure: a journal (`voice-memos-journal/<token>.move`: kind, id, source,
  destination, SHA-256, length, claim token) or the record's pending intent is
  written; playback of the id is stopped; an exclusive claim file
  ("rhymeai-claim\n<token>\n") is created at the destination and checked by
  content and file key; the source's digest and length are verified
  immediately before the rename; then the journal is cleared. Recovery removes
  only a file holding exactly its own claim, never an empty or unknown file.
  Expiry and Delete Forever of a recording are one locked operation: the record
  must still be in Trash with no pending intent and, for expiry, past its
  deadline at that moment; then the tombstone, the stop, the verify and the
  unlink happen under the same lock, so a restore cannot slip in between.
  Parked files from builds before A36 (`voice-memos-parking/<song>/<id>.<ext>`)
  return to their song at launch. Unreadable Trash file names, moves that
  cannot be finished and files left in place are reported after launch; the
  Trash Bin lists each unreadable Trash file by name and size (kept, never
  removed).
- New Song (Android): once the current draft is saved, the editor opens the new
  song at once; the stored selection is written afterwards, and only if nothing
  was typed meanwhile. A navigation asked for while a draft is being saved runs
  once that save is done (the latest one wins), saving the editor first again.
- A manifest or archive listing one recording id twice is refused before anything
  is applied. Restore and Import reconcile again right before their transactional
  apply and stop if that fails.
  iOS keeps an oversized journal (source and a completed flag) and finishes an
  interrupted move at retry.
- Import: both platforms find archive audio by recording id and verify it before
  writing it as `<id>.<ext>` with its display name; each recording that is
  damaged, missing from the archive or too large is counted once.
- Playback (A28): Android starts playback under the recording lock with a
  verified id (adopting a file seen for the first time), and every transition
  that moves bytes calls `RecordingTransitions.beforeBytesMove` under the same
  lock first, so playback stops before a Trash, restore, migration or quarantine
  move and no play can start in between; a rename moves nothing and playback
  continues. iOS stops playback through its `willMove` hook.
- iOS specifics (round 6): recording tombstones by id live in the CloudKit
  record type `SyncRecordingDeletion` (`SyncDeletionRecord` keeps song and
  legacy name tombstones, without a recording id); iOS drops `claimedName` and
  adds `displayName` on its CloudKit `Recording` type (A36); `pending-moves.json` also records
  Trash-detach intents (id, source, destination) before the deciding save; and
  `oversized-recordings.json` records an oversized take's id, name and finish
  time before its move. The manifest's only additions are the optional A37
  repair flags; the shared fixture is unchanged and its `fileName` values read as
  display names.
- Merge rules: per project id the newest `updatedAt` wins; per recording id
  Drive's entry wins; per tombstone identity the newest `deletedAt` wins; a real
  time beats a repair and of two repairs the smaller wins (A37).
  Tombstones apply by timestamp (A38): a song tombstone removes an active song
  when its `deletedAt` is newer than the song's real `updatedAt`, and a Trash
  entry when newer than the entry's real `trashedAt` (the entry's own
  `updatedAt` never overrides a tombstone; never the larger of the two); a
  recording tombstone, or its song's, removes a recording when newer than its
  real `uploadedAt`. A tombstone is itself a real time, so it beats any repaired
  (first-seen) time whatever the numbers (A41). A song or recording with a real
  time newer than its tombstone survives and the tombstone is dropped. A song
  (active or in Trash) on this device that loses only because its time was a
  repair is not erased, from whichever input it came (this device, Drive, an
  archive): Back up, Restore and Import keep its content (with both repair flags
  and its Trash time) and recording ids in a local recovery store
  (`recovered_songs_json`) before the manifest or the local lists that held it are
  written, and read it back (a mismatch stops the run). Back up skips only a
  version this device still lists with the same content; any other version of
  the same id is kept, and report "1 song with an unknown date was
  removed by a deletion; a copy is kept on this device." The store is readable
  through `ProjectRepository.recoveredSongs`; it has no UI yet, is not bounded and
  is not exported. A song that loses with a real time is a genuine deletion.
  Recordings: on Restore and Import every recording a winning tombstone removes
  is moved to quarantine (kept), whatever its time; a local song deletion
  deletes a recording with a real time and quarantines one whose time was a
  repair. In Drive, a raw object is removed only for a real-time loser; a
  repaired loser's raw object stays (unlisted) and is reported ("1 deleted
  recording with an unknown date was kept in your Google Drive."). When a song tombstone removes a recording, that
  recording gets its own tombstone at the same time, and deleting a song
  (Delete Forever or Trash expiry) writes tombstones for every recording this
  device holds for it in the same write, so reviving the song cannot bring the
  deleted audio back (on this device, in later backups, or from an offline
  device holding the same recording). Exception: a recording that was never in
  any backup and never on the deleting device (for example one recorded on an
  offline device and not yet uploaded) has no id anyone could tombstone; if the
  song is revived before that device backs up, the recording is treated as new.
  Every merge (backup write, retry, pre-write refresh, restore, apply, import,
  migration) first gathers all inputs' songs, trash, recording entries (live,
  Trash and oversized ones too) and tombstones, then applies the timestamp rule
  once; recordings this device cannot upload (Trash, too large, older ones that
  could not move) shape tombstones but are listed only if Drive already lists
  them. A raw file counts as present only when its `appProperties` hash and size
  both match. One id has one digest and one length forever (A40): this device
  uploads its own bytes for an id only when Drive holds no object under it; an
  object with another digest, another length, or no metadata is never written
  over or replaced, and the recording is reported ("N recordings were not
  uploaded because Google Drive holds different audio for them."). Several raw objects under one `rec_<id>` name
  (after a race) are all candidates: a download tries the one whose
  `appProperties` match first, then the others, and uses the first whose bytes
  match the manifest's size and digest, whatever order Drive lists them in.
  Android never writes over a raw `rec_` object: any object already under the
  id, whether its digest or its size differs, is refused and reported, and
  both stay. After a verified manifest write, a raw object is deleted only
  when a winning tombstone covers its id and its `appProperties` digest and
  size match an entry gathered in that same run; it is deleted by Drive file
  id, never by name.
- Back up versus restore: Back up now and the automatic backup merge this device
  into Drive and change no songs or recordings here (reconciliation and the
  first-seen stamping above, and the songs kept aside in the recovery store, are
  their only local writes). Restore merges both ways, uploads local-only
  items, then downloads recordings this device does not hold (live or in Trash).
  Restore and import apply in one repository transaction that resolves the
  incoming inputs with the current songs, Trash, tombstones and recording records,
  so an edit saved while they run is kept and a song deleted meanwhile stays
  deleted only if its tombstone is newer than the incoming version (A25). A
  download whose SHA-256 or size does not match the manifest is discarded and
  counted; recordings over 16 MiB are skipped with a visible count. An
  interrupted restore leaves only complete recordings; its recovery (run only at
  the start of Restore and Import) deletes the staging folder, which holds only
  verified downloads. A staging folder from the encrypted-sync build may hold
  that build's binary restore journal (magic `0x5248594D`, version 1, entries of
  index, project id, file name and had-original) with copies of the originals
  it replaced (`backup-<n>.tmp`), with or without `restore-complete`. At launch
  each original that differs from what its file holds now is first moved,
  journaled and verified, into its song as "<name> (original).<ext>" (or
  "(original 2)", …; never replacing a file), where migration adopts it; only
  then does the folder go. A journal that cannot be read keeps the folder
  untouched and the launch reports "An interrupted restore from an older
  version could not be finished. Its files were kept." Android hard
  links are not used because SELinux forbids them in app storage.
- Lost updates between devices: just before writing, the manifest list is read
  again; if another device wrote since the backup read it, the backup merges that
  manifest first. Every write is then downloaded again and its hash compared with
  the one just written; a mismatch re-merges and retries, up to three times,
  then reports "Backup conflict, will retry" and backs off. Each retry gathers
  the fresh manifest with everything earlier attempts saw, including a
  conflicting read-back. Drive v3 exposes no file ETag, so no `If-Match` is sent.
  Duplicate manifests are merged, the newest is kept, and the others are deleted
  only after the merged one verifies.
- Automatic backup: one 30 s debounce after any change to songs, trash,
  tombstones or recordings (recorded, saved, imported, renamed, deleted, trashed
  or restored, including recordings added by Import; a newly recorded memo starts
  the countdown on both platforms, A10) while connected, plus the
  background trigger when leaving the app (at most every 15 minutes unless a
  backup is pending); runs never overlap and a change during a run queues one
  more; after failures it retries at 1, 2, 4, 8 … minutes capped at one hour and
  resets on success (`BackupSchedulerTest`).
- Status model, same cases on both: `notConnected`, `connected(lastBackupAt?)`,
  `pending`, `backingUp`, `failed(reason, lastBackupAt?)`; Settings shows
  "Last backed up 2 min ago · Google Drive" or the failure reason with Retry.
- First-run restore: after Drive connects, or at launch when connected with an
  empty library, a manifest with at least one song offers "Restore your songs?"
  with Restore (merge) and Not now. Never automatic.
- Disconnect revokes the grant at `https://oauth2.googleapis.com/revoke`
  (Android with the current access token, then drops Play Services' cached
  token; iOS with the refresh token) and always clears local state. Only a
  successful revoke call counts; otherwise the copy reads "Disconnected on this
  device, but Google still lists the app; remove it at
  myaccount.google.com/permissions." Backups stop while disconnected.
- Migration from the encrypted backup (`rhymeai-projects.json`, RAI3/RAI2/RAI1
  manifests, RAI1 recordings; PBKDF2-HMAC-SHA256 210,000 iterations, AES-256-GCM,
  header as AAD), read only, and never applied to this device: with a stored
  passphrase each backup decrypts it, uploads its recordings raw (in memory) and
  merges its songs into the Drive manifest. The old files are never deleted:
  another older device may still write to them. A deleted old recording needs no
  raw copy (its encrypted original stays). Every old
  recording entry, with its original time, is gathered with all observed
  tombstones before resolving, so a song revived past its tombstone keeps the
  old takes that tombstone covered deleted. The migration counts as done, and
  the passphrase is forgotten, only when the written manifest verifies, every
  old song not removed by a tombstone (an active one compared by its
  `updatedAt`, a Trash entry by its `trashedAt`, A38) is in it with the same
  content or a newer edit, and every old recording not deleted is a raw file
  whose `appProperties` hash and size match and is listed with that hash. The
  device then remembers the migrated version (by the old file's id and
  modification time) and stops offering it; the old files stay in Drive, and a
  newer version written by an older device is offered again. The status reads
  "Your older encrypted backup was moved to the new format. Its files stay in
  your Google Drive." Older recordings keep their derived ids and original times;
  one that cannot move never stands in for another recording. Anything too
  large, unreadable or missing keeps the old backup, the
  passphrase and the "Migrate older encrypted backup…" row, and is reported ("2
  older recordings could not be moved; the older backup was kept."). Without a
  passphrase the old files stay untouched and the row asks once, storing
  nothing. If Drive needs consent first, the migration resumes after it with the
  phrase kept in memory only (Android `BackupAction.Migrate`). No old file: forget any stored passphrase. The shared RAI vectors
  stay as decrypt tests (`SyncBlobCryptoTest`, `BackupServiceTest`).
  Passphrases are normalized as before (trim space/tab/CR/LF, at least 8
  printable ASCII characters).
- Export all songs / Import from file: one zip `WritersBlock-backup-<date>.zip`
  with `manifest.json` (v4), `songs/<title or id>.txt`, `songs/<id>.json` and
  `recordings/<projectId>/<archive name>` by the one A39 allocator: within a song,
  recordings are visited by precedence time, then id (byte-wise); each takes its
  display name with "/", "\\" and leading dots turned into "_", or when that is
  taken "<stem> 2<ext>", "<stem> 3<ext>", … (first free counter); "taken"
  compares names NFC-normalized, then with Unicode default lowercasing (Kotlin
  `lowercase(Locale.ROOT)`, Swift `lowercased()`, Python `str.lower()`; not full
  case folding, so "İ", "ı" and "i" stay distinct); nothing is reserved ahead of its turn; the
  extension is the text after the last dot only when it is 1–16 UTF-8 bytes and
  leaves a stem (otherwise the whole name is the stem); the stem is cut so stem +
  suffix + extension fits 240 UTF-8 bytes, never below one code point. Pinned by
  `shared/fixtures/archive-names-v1.json` (`scripts/generate-archive-names-fixture.py`,
  stdlib, `--check`); iOS keeps a byte-identical copy at
  `Writers Block/Writers BlockTests/archive-names-v1.json`, and Android
  `BackupArchiveTest` fails if it drifts (it skips while the copy is absent).
  Import finds each recording's audio by id through the manifest and this same
  allocation, never by name alone, and the names never feed back,
  through the system save sheet; import
  takes that zip or a bare v4 `manifest.json`, rejects any archive with a `..`,
  absolute, drive-letter or backslash path or an entry outside those three
  places, and merges, adding only missing recordings that match their hash
  (`BackupArchiveTest`).
- Certificate pinning: Android pins `www.googleapis.com` and
  `oauth2.googleapis.com` fail-closed (no expiration) to GTS Root R4 with GTS
  R1-R3 and the GlobalSign cross-sign anchor as backups (verified 2026-10-22);
  `CertPinningInstrumentedTest` also shows the set refuses a chain outside it
  with a pin-verification failure, while the same chain validates against the
  system CAs without pins.
  Play Services fetches the Drive token outside the app. iOS pins the same Drive
  hosts with ATS `NSPinnedDomains` plus an in-app SPKI check on the session.
- iOS only (pending the companion PR): iCloud status shows a reason (no iCloud
  account with Open Settings, restricted, local-only fallback, temporarily
  unavailable, on), and recordings sync through CloudKit as a SwiftData
  `Recording` model with external audio storage (`displayName`,
  `displayNameChanged`, `precedenceRepaired`), from which the Drive recordings
  list is built; a recording removed on another device moves to the recordings
  Trash under its id. Recording id tombstones use the separate
  `SyncRecordingDeletion` record type so older builds never see them. Existing
  Drive users stay connected after updating. The iOS recorder stages each take in
  a folder named by its id with a finished marker, checks the container with
  AVAssetReader before saving, and shows "N recordings waiting to be saved" with
  Retry. Recordings over 16 MiB stay local, are listed in
  `oversized-recordings.json` and counted in Settings. iOS Trash files named
  `<ms>__name` are migrated to their ids at launch. Android has no CloudKit
  equivalent; its songs and recordings are also in Android Auto Backup.
- Not yet verified: a live Drive round trip on either platform, the iOS side,
  and a cross-platform restore.
- Drive HTTP error mapping: 401 re-auth, 403/429 retry-later, 5xx server-error,
  and generic fallback buckets are aligned; neither platform echoes raw
  response bodies into user-facing text.
- Sign-in failures: Android surfaces the Play Services status (developer
  error, cancelled, closed without granting access, network, or "code N") in
  the Backup status; iOS shows
  "Could not connect Google Drive: …" with the web sign-in error's description
  (known difference).
- Trash retention: 30 days on both platforms
  (`TrashedSongProject.kt` / `TrashedSongProject.swift`).
- Prompt templates: section labels, rhyme-constraint blocks, rewrite action
  instructions, and the Gemma chat template are byte-identical across
  platforms (iOS softens punch-up wording only on the Apple Intelligence
  local path due to on-device guardrails).
- Syllable coloring: identical two-toggle semantics — syllables on with rhyme
  highlight off tints whole words semibold; with rhyme highlight on, syllable
  color moves to the underline.

## Rhyme match highlight

- The Target Line's last word and each suggestion card's last word are drawn in the violet rhyme family colour (`#6D28D9` Ink/Paper, `#C4B5FD` Graphite; Android `rhymeMatchColor` = `rhymePalette(isDark)[4]`, iOS `analysisRhymeHexValues[4]`), semibold and underlined, on both platforms, gated by the rhyme highlight setting. Known difference: the iOS underline is at 60% alpha, the Android underline is the full colour (Compose `SpanStyle` has no separate underline colour). Android unit-verified in `RhymeMatchTextTest`.

## Rewrite highlight

- Pending-rewrite highlight: both platforms tint the selected lyric with the appearance's selection colour and a 1px strong-outline border while a rewrite (Harder Rhyme, Punch Up, and the rest) is pending or in flight, with no motion on the text; a failed rewrite uses the error colour. iOS previously used system indigo and teal with a 1.2s gradient sweep on a display link, Android the primary and success colours. iOS unit-verified in `RewriteRippleMotionTests` (palette colours per appearance, no layer animation while loading). Visual check on device pending on both.

## Suggestion loading motion

- Placeholders while suggestions stream: both platforms open one ghost slot when a request starts; each arriving line takes the ghost's slot with a 260ms cross-fade in place on the standard curve, the ghost fading out as the card fades in with no travel, and the next ghost opens below it while the request is still writing, so one ghost shows at a time, and the ghost still waiting leaves on the 160ms dismiss tier on the exit curve when the stream ends or is stopped, the whole section too when no line came (`SuggestionPlaceholderMotion` / `SuggestionInkLineMotion` `placeholderCount` and `slotCount`, unit-verified in `SuggestionPlaceholderMotionTest` and `SuggestionInkLineMotionTests`). Ghosts are held to the card's size by hidden text in the card's own fonts and the card's action layout, so they follow Dynamic Type and the Android font scale; the scribble is centred over the hidden line without sizing it, so a one-line card lands without moving the list. On both, each ghost scribbles two lines in the appearance's placeholder ink: the 34pt/dp wave, 10pt/dp tall, 1.6pt/dp round stroke, the last wave cut at the line's end, the second line 60% of the first's width, drawn tip first with the first line over 63% of a 1.3s write and the second after it, a 350ms hold, then a wipe and again, each ghost on its own clock (`lineProgress` and the wave points, unit-verified on both). When a request ends by itself with at least one line and no error (not on Stop, and not on a cancel from an edit or settings change mid-stream; Android counts these in `MainViewModel.suggestionRunsCompleted`), the Stop spinner bursts into fourteen dots of the on-surface ink over 480ms on an ease-out cubic, reaching 44pt/dp, with a collapsing 6pt/dp blot (`InkBurstMotion` on both, unit-verified in `InkBurstMotionTest` and `InkBurstMotionTests`). Both show a "Writing…" caption beside the heading; Android reads it as a polite live region, iOS announces "Writing suggestions". The primary button's label cross-fades on the 260ms state tier on both when it changes (Suggest Next Line and Stop; Android also Set up model). Reopening the panel or rotating mid-request shows the slots as they are instead of replaying their arrival. iOS Reduce Motion and an Android system animator scale of 0 both hold one scribble frame, the first line drawn and the second 60% along, skip the burst, and snap slot changes. Debug builds can hold and replay this state with no key, request or model through a scripted stream (iOS launch arguments `--ui-test-in-memory-store --ui-test-scripted-suggestions`, driven by `SuggestionLoadingUITests`; Android intent extra `com.rhymeai.app.SCRIPTED_SUGGESTIONS`, documented on `ScriptedSuggestionStream`). Android was checked frame by frame on an emulator at both animator scales; the iOS visual check is pending.
- Mid-stream invalidation: on both platforms a lyric edit, a cursor move, an inserted suggestion, and a change to the rhyme type, scheme, custom scheme or complexity cancel the in-flight request (Android `cancelEditorAIWork`, iOS `cancelSuggestions` from the `lyrics`, `cursorPosition` and rhyme-option observers). Known differences: Android also clears the lines already listed, iOS keeps them as it does for Stop; Android cancels on any selection change, iOS only when the published insertion point (`cursorPosition`, the selection's start as `LyricsTextView` reports it) moves, so growing a selection forward from the same start lets the stream finish (pinned in `CloudPrivacyFlowTests.growingASelectionFromTheSameStartKeepsTheRequest`). iOS unit-verified in `CloudPrivacyFlowTests.editorAndRhymeOptionChangesCancelAnInFlightRequest`.

## Editor and library motion ("More life" board)

Six small touches from the owner's "More life" board, on the DESIGN.md ladder (160 dismiss, 260 state, 420 settle; springs as named) with no new colour, shadow, glass or stagger. iOS is landed; Android implements the same board in parallel, so each line names the behaviour both must match. Every iOS animation goes through `rhymeAnimation` / `withRhymeAnimation` and degrades to the instant state under Reduce Motion; Android follows the system animator scale.

- Song open: the writing column (title, count line, lyrics) is keyed by an open token that `newProject` and `loadProject` refresh (iOS `EditorViewModel.editorOpen`); the outgoing page leaves on 160 dismiss and the incoming one arrives on 260 state, opacity only, no travel. An unsaved song's first autosave keeps its token, so it does not re-fade. Cursor and scroll restore run as before, and a focused lyrics editor keeps its focus across the open. Reduce Motion: one-frame swap. iOS `EditorOpenTokenTests` pins the token rule (a distinct token per open, including the same song reopened and New Song twice; none on the first autosave); the cross-fade itself, its durations and the scroll restore are checked by eye and by `testLongDraftRestoresVisibleScrollAndCaretWhenSwitchingSongs`, not by a unit test.
- New Song: after `newProject` the title field takes focus once the drawer or welcome has left (160ms), so the caret is in the title and the keyboard rises; opening a saved song keeps its restored cursor. No motion token. iOS UI-verified in `Writers_BlockUITests.testNewSongFocusesTheTitleFieldAndOpeningASongDoesNot`.
- Restore from Trash: the restored rows fade out on 160 dismiss while the rows below close the gap on the standard spring (iOS `Motion.presentation`, Android `standardSpring()`), and the drawer's toast confirms it: "Restored “title”" with an Open action for one song, "3 songs restored" with none for several, a checkmark in the success colour at the save indicator's 80%, text in primary ink; the toast enters on 260 state and leaves after 4s on 160 as the drawer's other toasts do. Reduce Motion: rows and toast appear and disappear in one frame. iOS `restoreTrashedProject` returns the restored song for Open (`TrashLifecycleTests`); UI-verified in `testMovingSongToTrashShowsFullPageTrashBinAndActions`.
- Use line: the insertion highlight (primary 12% fill, 45% border, 6pt radius) holds 2.0s on both platforms, then fades to 0 on the settle tier (iOS spring response 0.42, damping 0.80 on the overlay's alpha; Android `settleSpring()` on the highlight alpha) instead of clearing in one frame. The ghost, scribble, ink burst, violet rhyme match, rewrite highlight, toast and Undo are unchanged. Reduce Motion: one-frame clear. iOS `InsertionHighlightFadeTests` pins the 2.0s hold constant, that only a cleared insertion mark fades, that the clear takes the transaction's own animation and none when animations are disabled, and, through the overlay's injectable fade driver, that the mark stays drawn until the fade completes, is removed after it, and that a replacement survives the old fade's completion; the editor's hold task, its transaction wiring and the on-screen opacity curve are not unit-tested.
- Backup status: the Settings row's text and glyph cross-fade in place on 260 state; while it reads "Last backed up just now" (under 60s) the checkmark is the success colour at 80%, and at the next 30s refresh after the minute the glyph returns to secondary ink; the arrows rotate while a backup runs (iOS 18 `symbolEffect(.rotate)`, off under Reduce Motion). Android's progress indicator leaves on 160; iOS has none in that row. Copy, refresh cadence, error colour and row height are unchanged. Reduce Motion: one-frame swap, the colour still applies. iOS `BackupStatusGlyphTests` pins the glyph colour per status, the 80% opacity and the 60s boundary, each on Ink, Paper and Graphite; the cross-fade is checked by eye.
- Empty states: the drawer, recordings and Trash glyphs draw in the appearance's secondary ink at 100% (no system grey), with a title and one caption line naming the next action: "No saved songs yet." / "Create New Song starts a blank page."; "No recordings yet." / "Tap the mic in the editor to record a voice memo."; Trash keeps "Deleted songs stay here for 30 days.". When a list empties under the writer the state fades in on 260 state, opacity only; a tab switch stays instant. Search empty states keep their copy. Reduce Motion: appears in one frame.

## Assistant spacing

- Both Assistant panels and their suggestion and ghost cards are spaced on the same 8/13/21/34/55 rhythm ladder (Android `DesignTokens.Rhythm` in `AssistantPanel`, `SuggestionCard` and `SuggestionPlaceholderCard`; iOS applies the same five steps through `RhymeAITokens.Rhythm` in `AssistantPanelView`, `SuggestionCardView` and `SuggestionPlaceholderCardView`) with the same meaning per step: 8 within a control, 13 heading to its caption or control and between the scribble lines, 21 card padding and between cards, 34 between panel sections and at the panel's side edges, 55 primary (Android: 55dp above the primary button; iOS: a 55pt minimum button height with 8pt bar padding). DESIGN.md (Layout, Assistant panel rhythm) has the full mapping and the values that stay off the ladder.

## Regular-width layout

- iOS-only, known difference: on a regular width (iPad) the inline assistant column and the songs drawer both take 38.2% of the window with a 380pt floor (`RhymeAITokens.Layout.sideColumnWidth(for:)`; 380pt portrait, 456–462pt landscape on the 11-inch), the drawer as a leading side panel over a scrim, and the Trash screen keeps a centred 740pt column. Regular-width windows narrower than 760pt (Split View 1/2, small Stage Manager or windowed-app windows) drop the inline assistant column and open the assistant as the full-screen bottom panel, as on a compact width. The Word Inspector opens as a centred form sheet on a regular width and keeps its medium/large detents on a compact width. Android has no side-panel layout: its assistant is a bottom panel capped at 584dp, and its drawer and Trash stay full-width on tablets.

## Small motion touches

- Six settles from the "More life" board, built on Android (`feat/android-more-life`) with iOS implementing the same board in parallel; durations and copy are the parity contract, the mechanics differ by platform. Song open: the writing column fades, the old song out over 160ms on the exit curve and the new one in over 260ms on the standard curve, opacity only, cursor and scroll restored first. Known difference: Android runs the two in sequence (`MainViewModel.openingSong` holds every open, New Song, template and import for the dismiss tier at the system animator scale while the column fades out and the editor drops keystrokes, then `openRevision`, bumped by those four but not by a first autosave, starts the fade-in; an open that fails brings the column back), while iOS keys the column by an open token with an opacity transition, so its two fades overlap. New Song focuses the title only for the open it produced (`newSongOpenRevision`), so Welcome → Continue after a New Song does not raise the keyboard. Welcome ↔ editor: Android fades on the 140ms page tier (`RhymeNavGraph`), iOS on the 260ms state tier (pre-existing difference, unchanged). New Song: both put the caret in the title and raise the system keyboard once the blank page is up (Android `MainViewModel.newSongRevision` → `FocusRequester`; opening an existing song keeps its restored cursor). Restore from Trash: the row fades out on the dismiss tier and the rows below close on the standard spring (Android `animateItem`); the confirmation copy is "Restored “<title>”" with an Open action for one song and "N songs restored" with none, shown for 4 s in the drawer's existing snackbar (Android, Material shape) or toast (iOS); Android also animates the Trash's recordings rows the same way. Use line: the insertion highlight holds 2.0 s on both (Android was 1.8 s), then fades on the settle spring (Android `settleSpring`, damping 0.80, low stiffness; iOS response 0.42, damping 0.80); Android fades its 12% ink fill, which is all its insertion mark draws, while iOS fades fill and border. Backup status: text and glyph cross-fade in place, in over 260ms and out over 160ms, the progress indicator leaving on 160ms; while the line reads "just now" a checkmark in the success colour at 80% precedes the text, which stays in ink (Android had no glyph before and shows the check only in that state). Empty states: glyph in secondary ink at 100%, title, and the shared captions "Create New Song starts a blank page." / "Tap the mic in the editor to record a voice memo." / "Deleted songs stay here for 30 days."; a list that empties under the writer fades its empty state in over 260ms. Known difference: Android keeps its titles ("No saved songs yet.", "No recordings yet.", "No songs in the Trash Bin.") where iOS uses the system "No Songs in Trash". Reduced motion: Android gates every one of these on `LocalAnimationsEnabled` (one-frame swap, rows and states in one frame, colour and captions unchanged); iOS goes through `rhymeAnimation` (nil under Reduce Motion). Android verified in `SongOpenSettleUiTest`, `TrashRestoreMotionUiTest` and `BackupSectionUiTest` (each with an animations-off variant); iOS verification pending its PR.

## Open parity checks

- Local model live/inference path: Android has current emulator evidence for GGUF load and nonblank generation through `scripts/android-local-model-smoke.sh`; iOS local provider has a simulator/device smoke gate that passes when Apple Foundation Models either return text or surface an on-device availability reason.
- CloudKit live sync matrix: Static readiness is scriptable, but create/edit/concurrent edit/offline/delete/trash propagation still needs the live iCloud-signed-in two-simulator/device matrix in `docs/CLOUDKIT_SYNC_CHECKLIST.md`.
- Release walkthrough: iOS has a Release-configuration UI gate for create/save/export surface/graceful no-key AI/rewrite/relaunch persistence through `scripts/ios-release-walkthrough.sh`, a visual walkthrough screenshot gate for welcome, populated editor, export, assistant, and no-key AI/rewrite error states through `scripts/ios-release-visual-walkthrough.sh`, and a light/dark iPhone/iPad screenshot gate through `scripts/ios-release-visual-audit.sh`; Android has passing minified release APK walkthroughs for create/save/export surface/graceful no-key suggestion/force-stop/relaunch persistence through `scripts/android-release-walkthrough.sh`, live Gemini suggestion/rewrite preview through `scripts/android-release-live-gemini.sh`, and phone/tablet light/dark/large-font populated-surface screenshot coverage through `scripts/android-release-visual-audit.sh`.
- OpenAI/Claude happy paths: `scripts/provider-live-smoke.sh` is wired for BYO-key suggestion, rewrite, and streaming checks on both platforms; the live run is pending supplied keys. No-key/status/error messages are unit-verified.
