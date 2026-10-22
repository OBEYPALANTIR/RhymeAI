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
- PDF export: iOS unit-verified to produce PDF bytes from a long lyric sheet. Android instrumented-verified that a long lyric sheet produces readable PDF bytes, paginates through `PdfRenderer`, and renders visible ink on the first page.

## Trash and persistence checks

- Android sync merge: Unit-verified that active project changes merge by `updatedAt`, trash entries merge by `deletedAt`, newer trash removes stale active copies, and newer restored active projects are not deleted by stale trash entries.
- Recording deletions through Drive sync: both platforms write a `fileName` tombstone when a trashed recording is permanently deleted or expires from Trash (iOS `EditorViewModel.upsertPermanentDeletion`, Android `ProjectRepository.recordRecordingDeletion` via `VoiceMemoService.recordingDeletionRecorder`), written before the file is removed. Android also skips restoring a remote recording that sits in its local Trash (`RecordingSyncPlanner.planRestores(locallyTrashed)`). Known difference: iOS deletes local files named by incoming `fileName` tombstones (`deleteLocalRecordingsCoveredByDeletions`); Android only drops them from the manifest and upload set.
- iOS trash lifecycle and CloudKit readiness: In-memory SwiftData unit-verified that moving the current project to trash clears editor state, creates a 30-day trash entry, collapses duplicate trash rows with the same ID, restore collapses duplicate active/trash rows with the same ID, and purge removes only expired trash. `scripts/ios-cloudkit-readiness.sh` verifies the private CloudKit container, entitlements, remote-notification background mode, build output, and trash conflict tests before live sync.
- Import/autosave persistence: Android instrumented-verified that imported projects and debounced autosaves persist projects, current project ID, and editor state through DataStore and restore through a fresh ViewModel. iOS in-memory SwiftData unit-verified that imported projects and debounced autosaves persist the expected project fields and select the imported/saved project for editing.

## Prosody checks

- Android and iOS unit-verified shared dictionary stress counting, IPA stress markers, fallback syllable counts, punctuation/digit normalization, internal apostrophe retention, CMU rhyme keys, multi-pronunciation rhyme keys, stopword filtering, and short unknown-word rhyme suppression.
- Near and Slant next-line end-word lists: Android and iOS unit-verified (`NearSlantCandidateListTest(s)`) against the bundled dictionary and frequency list for chair, would, night, home, river, and alone. Both build them with the same tail classifier (`ProsodyAnalyzer.tailRelation`): Near is the same stressed vowel with a same-family consonant swap, one added or dropped consonant, an extra unstressed syllable, or shifted stress; Slant is consonance (identical coda, different vowel) or assonance (same vowel and syllable shape, unrelated consonants); a vowel before R counts as its own vowel. Each word takes its closest relation over every target x candidate pronunciation (Perfect > Near > Slant), the same rule `rhymeRelation` uses, so every listed word verifies as its list's relation (unit-verified for 14 multi-pronunciation anchors such as abuse, read, live, close, lead). Lists rank content words before function words, never include the anchor or its inflections, and return fewer words rather than padding. Returned suggestion lines go through the same filter on both platforms (`RhymeLineFilter`): the streaming path admits only the requested relation (tier 2 perfect, 1 near, 3 slant) in arrival order, never pads with misses, and reports "none matched the requested … rhyme" when every returned line misses; a chorus-hook ending only changes the badge. Unit-verified on Android in `SuggestionRhymeFilterTest` (filter) and `RhymeConstraintTest` (tiers), and on iOS in `RhymeConstraintTests` and `LocalGenerationBoundaryTests`.

## Local model checks

- Android Gemma GGUF download helpers are unit-verified for missing, incomplete, non-GGUF, valid GGUF, resumable partial download, HTTP failure, no-storage messaging, and progress formatting.
- Android local provider/model handling is unit-verified: the Local picker exposes only `local-model`, and suggestions, streaming, rewrites, and synonyms surface the shared no-model-loaded message without requiring an API key. A live `LocalModelInstrumentedTest` gate is wired through `scripts/android-local-model-smoke.sh` and passed on `emulator-5554` with an ignored TinyLlama Q2 GGUF fixture.
- iOS local provider/model switching is unit-verified: the Local picker exposes only `local-model`, selecting Local moves the current model to the on-device model, and Local does not require an API key.
- Resilient local suggestions: on both apps the on-device path (Android `validatedLocalSuggestionStream`; iOS `emitLocalLines`) no longer requires exactly six lines. After sanitize and the strict `RhymeLineFilter` (never padded with non-rhyming lines), fewer than six survivors retries the generation once (each local generate call draws a fresh seed: Android `LocalModelService` seed -1, iOS `GGUFModelService` random seed) and merges the retry's survivors, deduped by the suggestion key, after the first attempt's survivors up to six. Three to five survivors are shown as the suggestions with no error; fewer than three after the retry raises the existing incomplete / no-matching-rhymes error, and more than six are capped at six. Each generation gets its own raw-line budget (twelve accepted candidates when constrained); only dedupe keys and the shown count carry into the retry. A retry that throws (timeout, generation error, leaked markup) is treated like an empty retry when the first attempt already has three survivors; with fewer, its error surfaces. Cancellation always propagates. Unit-verified on both platforms for 6 survive (no retry), 4 survive + retry merges to 6, 4 survive + empty retry shows 4, 4 survive + failed retry shows 4, 2 survive + failed retry surfaces its error, and 2 survive after retry fails (`LocalSuggestionRetryTest`, `LocalGenerationBoundaryTests`).

## Next-line suggestion prompt

- Whole Song Context defaults on: an unset preference reads as on and an explicitly saved off is kept (iOS `editor.useWholeSongContext` in UserDefaults, Android `editor_use_whole_song_context` in DataStore via `ProjectRepository.DEFAULT_USE_WHOLE_SONG_CONTEXT`). Because cloud sharing follows this setting, a first cloud suggestion now asks for whole-song consent. Unit-verified on both platforms (`SuggestionPromptGuidanceTests` / `EditorTogglePersistenceTest`).
- Complexity wording is byte-identical (`RhymeComplexity.promptHint`, `finetune/eval/prompts.py` `RHYME_COMPLEXITIES`) and reaches both the on-device and cloud prompts. Simple and Complex carry numeric, checkable targets; only Complex asks for wordplay: Simple "Each line must be 4 to 7 plain, everyday words. Prefer one-syllable end words. No wordplay."; Moderate (default) "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever."; Complex "Each line must be 8 to 12 words. End each line on a word of two or more syllables, or put an internal rhyme inside the line. Use vivid, specific, less common words and double meanings."
- The allowed end-word list is level-aware (`RhymeConstraint.candidateEndWords(..., complexity)` via `levelEndWords` on both apps, `scoring.candidate_end_words(..., complexity=)` via `level_end_words` in the eval): the relation's frequency-ranked candidates are, at Complex, stably partitioned so words of two or more syllables come first; at Simple, reduced to one-syllable words unless fewer than six exist, when the remaining words follow in their original order; at Moderate (the default for every caller that does not pass a level) left exactly as before. Syllables come from each platform's `ProsodyAnalyzer.analyzeWord` / `syllable_count_word` with the same dictionary. The level reaches the list on every suggestion path: Android `suggestionRhymeConstraint(..., complexity)` from `streamSuggestions` and the cloud prompt's own rebuild without whole-song context; iOS `rhymeConstraintBlock`/`rhymeConstraintWords(..., complexity:)` from `buildPrompt` and `buildLocalPrompt`; the eval's `run_eval.prepare_case`. The shared fixture `shared/fixtures/complexity-end-words-v1.json` (11 anchors x 3 relations x 3 levels, produced by `finetune/eval/complexity_end_words_fixture.py`) pins Android and the eval word for word; iOS asserts the Perfect level rule on its bundled dictionary (no Near/Slant fixture test there). The eval's `scoring.find_rhymes` / `rhyme_relation` port the apps' exclusive perfect/near/slant pools and `rhymeRelation` (every pronunciation pair, songwriter order), so `ordered_candidates` draws Near and Slant from the relation's own pool and `rhyme_tier` returns 3 for slant, as the apps do. Simple only prefers one-syllable endings because its list falls back to longer words (anchors such as "arrival" and "river" have no one-syllable rhyme; "love" and "world" have four and five, under the six distinct endings the on-device rule asks for) and because chorus hook words are never filtered by the level. Chorus repeat (2nd+): Android and the eval put first-chorus end words that stand in the requested rhyme relation to the target first, verifying the relation directly (`ProsodyAnalyzer.rhymeRelation` on Android, `scoring.rhyme_relation` in the eval) rather than by membership in the 12-word list, then cut the merged list back to 12, so a hook the Complex or Simple ordering pushed past the cut is still promoted; iOS prepends every first-chorus end word unfiltered (pre-existing difference, unchanged). Neither reapplies the level after the merge, so hooks stay in front at every level.
- On-device prompt guidance is byte-identical: after the rhyme hint and constraint block comes "The writer is stuck on the next line and wants ideas to pick from, not a finished verse.", and the Rules list (after "Return only candidate lyric lines.") adds six-different-directions, "End each line on a different word from the allowed list." when the list has at least six distinct words (case-folded, so a later chorus that lists its hook word several times counts it once), "The allowed list has fewer than six words, so end words may repeat, but the six lines must still be six different ideas." when it has one to five, and "End each line on a different word." when no list is sent (`localEndWordRule`; unit-verified for 3- and 6-word lists and for repeated chorus end words), the raw-material/own-voice rule, the do-not-resolve rule and the stay-inside-the-song rule. The six-line count, format rules and parsers are unchanged. Cloud prompts are prose without a Rules list and ask for 12 candidates, so they only pick up the complexity wording. `finetune/eval/prompts.py` mirrors the Android builder.
- Context & Theme is independent of Whole Song Context: the field stays editable in both modes, and a non-empty theme is sent in every suggestion prompt (on-device "Theme: …", cloud "theme/context: …"), together with the full lyric when Whole Song Context is on. Only an empty theme falls back to "Infer from the lyrics." (on-device) or, in the cloud prompt, "Whole song context enabled; infer the theme from the full lyrics." / "No specific theme provided". The coupling came from `7fc6552` ("Keep context box fixed"), which disabled the field and replaced the theme whenever Whole Song Context was on; it was not a consent rule. Cloud consent is unchanged: the scope follows Whole Song Context only, and both scopes' disclosures already list the theme. Unit-verified on both (`themeIsSentWithWholeSongContext`). Because the field stays editable while a request runs, any theme change cancels in-flight AI work (suggestions, rewrite, synonyms, a pending consent prompt) and clears the shown suggestions and error, so results for the previous theme never land: Android `onThemeChanged` → `cancelEditorAIWork` (instrumented `changedContextRejectsLateResultsAndCancelsActiveWork`), iOS `theme.didSet` → `cancelEditorAIWork` (unit `themeEditDropsInFlightSuggestionsWithWholeSongContextOn`).
- On-device lyric window (Android `AIService.localLyricWindow` via `localLyricsContext`, iOS `AIService.localLyricWindow`, Python `local_lyric_window`), budget 3,100 UTF-16 units with Whole Song Context on (900 of them for the song's opening), and on Android only 2,600 with it off (no opening). Lyrics within the budget after whitespace trimming are sent as is. Longer lyrics are split on "\n" and keep, in order: (1) the cursor's blank-line-delimited stanza (the same block `NextLinePlacement` uses, ending at the cursor when the cursor line is blank) plus the lines directly above and below the cursor; (2) the song's opening lines up to the opening allowance; (3) the lines nearest that window, one above then one below, while they fit. Room for two marker lines is reserved, so the result never exceeds the budget. Each skipped run that contains a lyric becomes one "[Lyrics trimmed for on-device speed]" line; the result is whitespace-trimmed. If the stanza alone is over the budget, only the cursor's neighbours are pinned and the nearest-line fill takes the rest of the stanza; if the neighbours are still over, only the cursor line is pinned. A cursor line longer than the budget keeps its end (where the next line is inserted) after a marker, cut on UTF-16 units and never starting on a low surrogate, so the output never exceeds the budget (unit-verified on both by sweeping every cursor line of every fixture song). The cursor line is `NextLinePlacement.cursorLineIndex` (no cursor means the last line). Byte-identical output is proven by the shared fixture `shared/fixtures/local-lyric-window-v1.json` (a 300-line song with the cursor at the start, a middle lyric line, a middle blank line, the end and no cursor; a single 4,000-character line; a 3-line stanza whose middle line is 4,000 characters with the cursor on each line; and a line of 2,000 non-BMP emoji (4,000 UTF-16 units); expected values produced by `finetune/eval/prompts.py`, which also counts and cuts in UTF-16 units): Android checks all 22 cases, iOS the 11 whole-song cases from a bundled copy (`Writers Block/Writers BlockTests/local-lyric-window-v1.json`, which the simulator can read and the Android test checks is byte-identical to the shared file), and both check that the built prompt carries the window for the cursor.
- Known differences: with Whole Song Context off, iOS sends the cursor's stanza untrimmed (pinned by `localPromptRetainsLongStanzaAndWholeSongPolicy`), while Android sends the whole lyric through the window above. Android rewrites also use the 2,600 window with the cursor at the last line. The on-device rhyme hint and whole-song instruction wording still differ between platforms.

## Rhyme context checks

- Android and iOS unit-verified that section headers do not consume rhyme-scheme positions, latest previous lyric lines with the same scheme letter become the rhyme target, current section detection reaches prompt shaping, and empty lyrics use the first active scheme letter. Android pure seam additionally verifies cursor clamping and empty-scheme fallback to `A`.
- Rhyme-scheme display row accounting follows Android `RhymeSchemeDisplay.kt` (`rhymeSchemeRows` at #55 candidate `5d401dff`): section headers and non-current blank/whitespace rows show no letter and consume no scheme position; the current blank shows `currentLetter` without consuming one; lyric rows advance and wrap through the scheme. iOS source/host verification is tracked in the G6 handoff; simulator/UI parity remains unverified.

## Cloud backup parity checks

Backup v4 is specified for both platforms; the Android side is implemented and
tested here. The iOS side is pending the companion PR, so every iOS statement
below is the contract it must meet, not verified behaviour.

- Backup format (v4): Drive `appDataFolder` holds the plain manifest
  `rhymeai-manifest.json` and one raw `rec_<projectId>_<fileName>` per
  recording, uploaded with `appProperties` `projectId`, `fileName`, `sha256` and
  `bytes` (Android omits a property whose key plus value exceeds Drive's
  124-byte limit; the manifest stays authoritative). Manifest keys: `version`
  (4), `savedAt` (ISO-8601 UTC, whole seconds, `Z`), `savedByClientId`,
  `platform`, `projects`, `trashed` (project fields plus `trashedAt`),
  `recordings` (`projectId`, `fileName`, `bytes`, `sha256`, `uploadedAt` as
  ISO-8601 UTC), `deletions` (`projectId`, `fileName` or null, `deletedAt`) and
  `manifestSha256`. Song, trash and tombstone timestamps are epoch milliseconds,
  as in v3. No passphrase, no client-side encryption; API keys never enter the
  manifest.
- Canonical form and hash: `manifestSha256` is the SHA-256 of the object
  without that key, serialised with keys sorted by Unicode code point, arrays
  in stored order, no whitespace, UTF-8, integers only, and escapes limited to
  `\"`, `\\`, `\n`, `\r`, `\t` and lowercase `\u00xx` for other control
  characters (non-ASCII is not escaped). The uploaded file may be pretty-printed.
  Readers refuse a hash mismatch ("Backup file is damaged; it was not merged.")
  and any `version` above 4, and never overwrite such a file. Pinned by
  `shared/fixtures/sync-manifest-v4.json` (`scripts/generate-sync-manifest-v4-fixture.py`,
  stdlib only, `--check`); iOS reads the copy at
  `Writers Block/Writers BlockTests/sync-manifest-v4.json`, and Android
  `BackupManifestTest` fails if it drifts (it skips while the copy is absent).
- Merge rules: per project id the newest `updatedAt` wins; per deletion
  identity the newest `deletedAt` wins. Tombstones apply by timestamp: a song
  tombstone removes the song only when `deletedAt` is newer than its `updatedAt`
  (and, in Trash, its `trashedAt`); a recording tombstone, or its song's, removes
  a recording only when newer than its `uploadedAt` (a local file not yet listed
  uses its modification time). A song or recording newer than its tombstone
  survives and the tombstone is dropped. The same rule runs in the merger, the
  local apply and the upload filter (`SyncMergerTest`, `BackupServiceTest`,
  `ProjectRepositoryTest`). Recordings are immutable, so Drive's entry wins per
  identity; a listed recording whose raw file is missing, or whose
  `appProperties` hash differs, takes the uploading device's copy.
- Back up versus restore: Back up now and the automatic backup merge this device
  into Drive and never change local data. Restore merges both ways, uploads
  local-only items, then downloads missing recordings. Restore and import apply
  in one repository transaction against the current data, so an edit saved
  while they run is kept. A download is written only if nothing is at its
  destination when it commits (create-if-absent hard link); a file that appeared
  meanwhile is kept and the download dropped. A download whose SHA-256 or size
  does not match the manifest is discarded and counted. Recordings over 16 MiB
  are skipped with a visible count.
- Lost updates between devices: every manifest write is downloaded again and
  its hash compared with the one just written; a mismatch (another device wrote
  in between) re-merges with the newer manifest and retries, up to three times,
  then reports "Backup conflict, will retry" and backs off. Drive v3 exposes no
  file ETag, so no `If-Match` is sent. Duplicate manifests are merged, the newest
  is kept, and the others are deleted only after the merged one verifies.
- Automatic backup: one 30 s debounce after any change to songs, trash,
  tombstones or recordings (saved, imported, renamed, deleted, trashed or
  restored) while connected, plus the background trigger when leaving the app
  (at most every 15 minutes unless a backup is pending); runs never overlap and a
  change during a run queues one more; after failures it retries at 1, 2, 4, 8 …
  minutes capped at one hour and resets on success (`BackupSchedulerTest`).
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
  merges its songs into the Drive manifest. The old manifest, its `rec_*`
  files and the passphrase are removed only when the written manifest verifies
  and every old song not removed by a newer tombstone is in it with the same
  content or a newer edit, and every old recording is a raw file whose
  `appProperties` hash and size match. Anything too large, unreadable, missing
  or held under the same name with different bytes keeps the old backup, the
  passphrase and the "Migrate older encrypted backup…" row, and is reported ("2
  older recordings could not be moved; the older backup was kept."). Without a
  passphrase the old files stay untouched and the row asks once, storing
  nothing. No old file: forget any stored passphrase. The shared RAI vectors
  stay as decrypt tests (`SyncBlobCryptoTest`, `BackupServiceTest`).
  Passphrases are normalized as before (trim space/tab/CR/LF, at least 8
  printable ASCII characters).
- Export all songs / Import from file: one zip `WritersBlock-backup-<date>.zip`
  with `manifest.json` (v4), `songs/<title or id>.txt`, `songs/<id>.json` and
  `recordings/<projectId>/<fileName>`, through the system save sheet; import
  takes that zip or a bare v4 `manifest.json`, rejects any archive with a `..`,
  absolute, drive-letter or backslash path or an entry outside those three
  places, and merges, adding only missing recordings that match their hash
  (`BackupArchiveTest`).
- Certificate pinning: Android pins `www.googleapis.com` and
  `oauth2.googleapis.com` fail-closed (no expiration) to GTS Root R4 with GTS
  R1-R3 and the GlobalSign cross-sign anchor as backups (verified 2026-10-22);
  `CertPinningInstrumentedTest` also proves the set refuses a chain outside it.
  Play Services fetches the Drive token outside the app.
- iOS only (pending the companion PR): iCloud status shows a reason (no iCloud
  account with Open Settings, restricted, local-only fallback, temporarily
  unavailable, on), and recordings sync through CloudKit as a SwiftData
  `Recording` model with external audio storage, from which the Drive
  recordings list is built. Android has no CloudKit equivalent; its songs and
  recordings are also in Android Auto Backup.
- Not yet verified: a live Drive round trip on either platform, the iOS side,
  and a cross-platform restore.
- Drive HTTP error mapping: 401 re-auth, 403/429 retry-later, 5xx server-error,
  and generic fallback buckets are aligned; neither platform echoes raw
  response bodies into user-facing text.
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

## Assistant spacing

- Both Assistant panels and their suggestion and ghost cards are spaced on the same 8/13/21/34/55 rhythm ladder (Android `DesignTokens.Rhythm` in `AssistantPanel`, `SuggestionCard` and `SuggestionPlaceholderCard`; iOS applies the same five steps through `RhymeAITokens.Rhythm` in `AssistantPanelView`, `SuggestionCardView` and `SuggestionPlaceholderCardView`) with the same meaning per step: 8 within a control, 13 heading to its caption or control and between the scribble lines, 21 card padding and between cards, 34 between panel sections and at the panel's side edges, 55 primary (Android: 55dp above the primary button; iOS: a 55pt minimum button height with 8pt bar padding). DESIGN.md (Layout, Assistant panel rhythm) has the full mapping and the values that stay off the ladder.

## Regular-width layout

- iOS-only, known difference: on a regular width (iPad) the inline assistant column and the songs drawer both take 38.2% of the window with a 380pt floor (`RhymeAITokens.Layout.sideColumnWidth(for:)`; 380pt portrait, 456–462pt landscape on the 11-inch), the drawer as a leading side panel over a scrim, and the Trash screen keeps a centred 740pt column. Regular-width windows narrower than 760pt (Split View 1/2, small Stage Manager or windowed-app windows) drop the inline assistant column and open the assistant as the full-screen bottom panel, as on a compact width. The Word Inspector opens as a centred form sheet on a regular width and keeps its medium/large detents on a compact width. Android has no side-panel layout: its assistant is a bottom panel capped at 584dp, and its drawer and Trash stay full-width on tablets.

## Open parity checks

- Local model live/inference path: Android has current emulator evidence for GGUF load and nonblank generation through `scripts/android-local-model-smoke.sh`; iOS local provider has a simulator/device smoke gate that passes when Apple Foundation Models either return text or surface an on-device availability reason.
- CloudKit live sync matrix: Static readiness is scriptable, but create/edit/concurrent edit/offline/delete/trash propagation still needs the live iCloud-signed-in two-simulator/device matrix in `docs/CLOUDKIT_SYNC_CHECKLIST.md`.
- Release walkthrough: iOS has a Release-configuration UI gate for create/save/export surface/graceful no-key AI/rewrite/relaunch persistence through `scripts/ios-release-walkthrough.sh`, a visual walkthrough screenshot gate for welcome, populated editor, export, assistant, and no-key AI/rewrite error states through `scripts/ios-release-visual-walkthrough.sh`, and a light/dark iPhone/iPad screenshot gate through `scripts/ios-release-visual-audit.sh`; Android has passing minified release APK walkthroughs for create/save/export surface/graceful no-key suggestion/force-stop/relaunch persistence through `scripts/android-release-walkthrough.sh`, live Gemini suggestion/rewrite preview through `scripts/android-release-live-gemini.sh`, and phone/tablet light/dark/large-font populated-surface screenshot coverage through `scripts/android-release-visual-audit.sh`.
- OpenAI/Claude happy paths: `scripts/provider-live-smoke.sh` is wired for BYO-key suggestion, rewrite, and streaming checks on both platforms; the live run is pending supplied keys. No-key/status/error messages are unit-verified.
