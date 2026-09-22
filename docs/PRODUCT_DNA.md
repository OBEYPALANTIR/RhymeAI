# RhymeAI Product DNA

## Purpose and Status

This document is the product-level decision filter for RhymeAI. It describes what the product is, who it serves, what must feel distinctive, and what evidence is still missing. It does not replace `DESIGN.md`, `PARITY.md`, release checklists, or the implementation.

Read it before changing product scope, primary journeys, information architecture, user-facing language, AI behavior, privacy defaults, brand, monetization, growth mechanics, or portfolio relationships. Update it only when a product decision changes; do not rewrite it to rationalize an implementation after the fact.

Verify the working checkout directly. A source tree, artifact, or result from another checkout does not establish the state of this one.

## Product Classification

- **Portfolio status:** current product.
- **Category:** native creator tool and songwriting workspace.
- **Primary value:** help a songwriter stay in creative flow while preserving authorship and control.
- **Delivery surfaces:** native Android and native iOS. Native Mac work remains separate and unfinished, outside the mobile parity surface.
- **AI posture:** optional assistant with cloud-provider choice and local-model paths, never the owner of the song.

## Users and problems

Primary users are independent songwriters, lyricists, vocalists, and music makers who draft on a phone or tablet and want help without surrendering their voice. The product should also remain approachable to a new writer who does not know rhyme-scheme or prosody terminology.

Core jobs:

1. Capture and safely continue a lyric idea before creative momentum disappears.
2. Organize songs and sections without turning writing into project administration.
3. Understand rhyme, syllable, stress, and pronunciation in context.
4. Request several useful possibilities, review them, and choose whether to apply one.
5. Move work between devices or export it without losing formatting or ownership.
6. Choose cloud or on-device assistance according to privacy, quality, storage, and latency needs.

## Product principles

1. **The lyric stays central.** Tools support the writing surface and recede when not needed.
2. **The writer remains the author.** Suggestions are options; application is explicit and reversible.
3. **Native on purpose.** Android and iOS follow their platform conventions while preserving equivalent user outcomes.
4. **Private by default.** Local work and local inference are first-class; network use and credential handling are explicit. Local is the initial provider and the first setup option. Preserve valid provider choices already made by the writer; a missing local model leads to local setup, not an automatic cloud fallback.
5. **Explain just enough.** Advanced rhyme and prosody insight should be discoverable without burdening a first draft.
6. **Fast feedback protects flow.** Loading, streaming, cancellation, failure, persistence, and recovery states must be visible.
7. **Evidence outranks aspiration.** A model, provider, sync path, or release is not ready until its real user journey is observed.

## Signature experiences

- A quiet lyric-first editor with projects, sections, autosave, trash recovery, and export.
- Section-aware rhyme context that understands the cursor’s current stanza and target pattern.
- “UnBlock” assistance that streams multiple next-line options and supports rewrite actions such as rephrase, harder rhyme, and punch up.
- Optional rhyme highlighting, syllable counts/coloring, stress, IPA, and beat-grid aids that do not overwhelm plain writing.
- Review-before-apply flows that preserve the original lyric and make cancellation safe.
- Provider and model choice across supported cloud services and on-device paths, with honest availability and error states.
- Cross-platform behavior that feels native on each platform while keeping prompts, parsing, persistence expectations, and user-visible outcomes aligned.

## Technology patterns

- Android: Kotlin, Jetpack Compose, Material 3, coroutines, ViewModel state, Preferences DataStore, Android encrypted credential storage, and GGUF/local-model support.
- iOS: Swift, SwiftUI, SwiftData, optional CloudKit-backed persistence, `UserDefaults` for non-secret preferences, Keychain for credentials/secrets, and local-model services.
- Shared: pronunciation/prosody source assets generated into both native targets; cross-platform prompt, parsing, export, backup-envelope, and retention contracts where behavior must match.
- External systems: Gemini, OpenAI, Claude, Google Drive app data, CloudKit, model hosting/downloads, Apple signing, and Android signing. Their live state must be verified, not inferred from configuration.

Secrets never belong in DataStore or `UserDefaults`. Lyrics, song metadata, provider responses, and credentials are different data classes and must not be logged or transmitted as if they were interchangeable.

## Design and brand patterns

The brand is editorial, tactile, focused, and restrained rather than “AI dashboard” chrome. The authored appearances are Ink Editorial, Paper Notebook, and Graphite Night. Ink is the crisp default; Paper is warm and flat; Graphite is dark with only the subtle static treatment allowed by `DESIGN.md`.

Serif display type may add literary character while body and lyric text remain highly readable. Monochrome structure leads; semantic colors communicate status, rhyme, syllable, warning, or recording meaning. Motion should acknowledge an action or transition, never compete with the words, and must respect reduced-motion and accessibility settings.

Voice is direct, calm, and collaborative. Prefer “suggest,” “review,” “try again,” and concrete recovery steps. Avoid claims that AI “knows” the writer, anthropomorphic pressure, generic productivity language, or technical provider details where a user only needs a clear state.

## Business and growth patterns

The repository does not establish a verified pricing model, entitlement strategy, acquisition channel, retention target, analytics policy, support model, or portfolio cross-sell contract. Treat all of these as open product decisions.

Before adding monetization or growth mechanics, define the user benefit, privacy/consent boundary, store-policy implications, success metric, failure/rollback path, and whether the mechanic interrupts writing. Do not gate access to a user’s own lyrics, exports, deletion, or credential removal. Do not add analytics to private creative content by default.

## Quality and risk posture

- **Loss of work:** autosave, import/export, trash, restore, sync, and conflict behavior need persistence and relaunch evidence.
- **Authorship harm:** prompt echo, unsafe replacement, low-quality rhyme, or opaque application can overwrite voice; preserve review and reversibility.
- **Privacy/security:** plaintext credentials, verbose provider errors, lyric logging, insecure backups, or embedded test keys are release blockers.
- **Parity drift:** shared user outcomes can diverge behind native implementations; update and test `PARITY.md` contracts deliberately.
- **AI variability:** parsing, cancellation, timeouts, blocked responses, offline behavior, and model quality need deterministic seams plus live gates.
- **Local-model cost:** download size, integrity, storage, cold load, memory, latency, and device capability must be visible and measured on the stated target.
- **Accessibility:** keyboard overlap, small targets, unlabeled controls, large-text overflow, contrast, motion, and tablet adaptation are product failures, not polish debt.
- **Release dependence:** signing, provisioning, store state, provider keys, simulator/device state, and cloud accounts can invalidate otherwise passing local tests.

## Reuse and avoidance guidance

Reuse shared pronunciation data, prompt/parsing contracts, backup-envelope rules, privacy patterns, semantic language, test scenarios, and evidence formats when they genuinely span platforms. Prefer shared fixtures and contract tests over duplicated prose.

Do not reuse screenshots as implementations, force pixel identity across native platforms, hardcode provider/model assumptions, copy secrets or production data into fixtures, revive the removed web client, import another portfolio product’s navigation metaphor, or treat an older reference project as current architecture. Avoid novelty that moves attention away from the lyric.

## Evidence index

- `README.md` — current surfaces, features, local verification, release/live gate entry points.
- `DESIGN.md` — authored appearances, tokens, components, responsive rules, accessibility, and motion constraints.
- `PARITY.md` — aligned behavior, verified coverage, and open Android/iOS gaps.
- `AGENTS.md` — repository workflow, security boundary, commands, approvals, and evidence-reporting contract.
- `android/app/build.gradle.kts` and `android/app/src/main/AndroidManifest.xml` — Android SDK, dependencies, build/signing behavior, permissions, and app boundary.
- `android/benchmark/build.gradle.kts` — this checkout’s Android macrobenchmark test target and benchmark build contract.
- `android/app/src/main/kotlin/com/rhymeai/app/data/repository/ProjectRepository.kt` and `SecureKeyStore.kt` — DataStore versus encrypted-secret responsibilities.
- `Writers Block/Writers Block/ViewModels/EditorViewModel.swift`, `Services/KeychainStore.swift`, and `Writers_BlockApp.swift` — iOS state, preferences, credentials, SwiftData, and CloudKit behavior.
- `Writers Block/Frameworks/README.md` — this checkout’s pinned, vendored llama.cpp XCFramework provenance, slices, checksum, and license note.
- `shared/pronunciation/` and `scripts/generate-pronunciation-assets.mjs` — shared prosody assets and generation path.
- `scripts/verify.sh`, platform release/walkthrough/visual scripts, provider/live scripts, and `scripts/final-signoff-status.sh` — executable verification and readiness boundaries.
- `finetune/README.md`, `finetune/SCORECARD.md`, and `finetune/train/RUNBOOK.md` — local-model provenance, quality evaluation, and training workflow; these are evidence inputs, not automatic release approval.
