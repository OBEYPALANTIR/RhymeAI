# CLAUDE.md

This file gives Claude Code the repo map for RhymeAI / Writers Block.

## Repo Shape

RhymeAI is now native-first. The active targets are:

- `android/` — native Kotlin + Jetpack Compose app, package `com.rhymeai.app`.
- `Writers Block/` — native SwiftUI iOS app.
- `shared/pronunciation/` and `scripts/` — shared CMU-backed prosody assets and generation tooling.

The old React/Vite web variant has been removed. Do not reintroduce root `package.json`, `src/`, Vite, or Capacitor files unless Tyler explicitly asks for a web target again.

## Android

Android state is centered in `android/app/src/main/kotlin/com/rhymeai/app/MainViewModel.kt`.

Important Android files:

- `service/AIService.kt` — provider/model enums, section-aware prompts, streaming Gemini/OpenAI/Claude calls, local-model prompt flow.
- `service/LocalModelService.kt` — GGUF local-model loading and generation.
- `data/repository/ProjectRepository.kt` — DataStore persistence for projects, trash, editor state, provider/model choice, and API keys.
- `ui/screens/EditorScreen.kt` and `ui/components/AssistantPanel.kt` — editor, assistant sheet, rewrite and suggestion UI.
- `util/ProsodyAnalyzer.kt`, `RhymePhonetics.kt`, `SyllableCounter.kt` — shared pronunciation-driven analysis.

Run Android commands from `android/` using the wrapper:

```sh
./gradlew :app:assembleDebug
./gradlew :app:compileDebugKotlin
./gradlew :app:testDebugUnitTest
./gradlew :app:lintDebug
./gradlew :app:connectedDebugAndroidTest
```

## iOS

iOS state is centered in `Writers Block/Writers Block/ViewModels/EditorViewModel.swift`.

Important iOS files:

- `Services/AIService.swift` — provider/model enums, section-aware prompts, streaming Gemini/OpenAI/Claude calls, Apple Intelligence local flow.
- `Services/ProsodyAnalyzer.swift`, `RhymePhonetics.swift`, `SyllableCounter.swift` — pronunciation-driven analysis.
- `Views/EditorView.swift`, `Views/AssistantPanelView.swift`, `Views/ProjectsDrawerView.swift`, `Views/TrashBinView.swift` — main app surfaces.

Before command-line iOS builds, confirm schemes and simulator destinations:

```sh
xcodebuild -list -project "Writers Block/Writers Block.xcodeproj"
xcrun simctl list devices
```

## Working Rules

- Preserve native parity when changing prompts, rhyme context, prosody, trash, or provider/model behavior.
- Keep API keys out of source. Android stores runtime keys through `SecureKeyStore`/EncryptedSharedPreferences; iOS stores runtime keys in Keychain. `android/local.properties` is local SDK configuration only.
- Check `DESIGN.md` before UI changes.
- Do not commit screenshots, simulator captures, APKs, or files under `artifacts/`.

## Harness: RhymeAI

**Goal:** land cross-platform RhymeAI changes (Android, iOS, eval) on `main` with run evidence and an independent review, and improve the on-device models through the teacher-data and Colab student pipelines.

**Issue tracking:** GitHub Issues — the orchestrator pulls ready work with `gh issue list --state open` / `gh issue view <n>`; status is written back by the PR's `Fixes #<n>` closing the issue on merge, plus a `gh issue comment` with the merge commit.

**Entry point — applies to every prompt in this repo:** You MUST invoke the `rhymeai-orchestrator` skill *before* responding to any request — new work, a follow-up, a re-run, a question, or a change to a previous result. It is the single entry point; do not craft a response outside it. The orchestrator decides what happens next: it answers trivial or out-of-RhymeAI requests directly and runs the agents only when the work warrants it.

**Delegated agents are exempt from the gate:** when you are running as one of the harness's workers (`rhymeai-implementer`, `rhymeai-verifier`, `rhymeai-model-trainer`, `android-m3-expressive-designer`, or any agent the orchestrator spawned with a delegation prompt), do not invoke `rhymeai-orchestrator`; do the delegated task and return your report. The gate applies to the session's top-level conversation only.

**Change history:**
| Date | Change | Target | Reason |
|------|--------|--------|--------|
| 2026-10-08 | Initial setup: orchestrator, 3 agents, 4 skills, tools registry; 74 off-domain skills archived locally | All | harness review found no entry point and no skill for the real workflows |
| 2026-10-08 | Tool discovery: registered kotlin-lsp, swift-lsp, gguf-py, colab-mcp, inspect-ai by role; secret gists kept as evidence host | `skills/rhymeai-orchestrator/references/tools.md` | owner accepted each candidate; language servers and Colab MCP installed at user scope |
| 2026-10-08 | Delegated agents exempted from the entry-point gate; model work routed to the trainer before implementation; designer agent memory path made checkout-relative | `CLAUDE.md`, `skills/rhymeai-orchestrator`, `agents/*` | Codex review of PR 92: recursive orchestration, wrong phase order, checkout-specific path |
| 2026-10-08 | iOS test command in the registry now carries project, scheme and destination; `.agents/worktrees/` ignored in the shared gitignore | `references/tools.md`, `.gitignore` | Codex review of PR 92, second pass |
| 2026-10-08 | Workers declare their skills in frontmatter so they load at spawn; designer memory exclusions narrowed to generic code | `agents/*` | Codex review of PR 92, third pass |
| 2026-10-08 | iOS tests registered as the guarded `scripts/verify.sh` stage; issue closure made conditional on an issue existing | `references/tools.md`, `skills/rhymeai-orchestrator` | Codex review of PR 92, fourth pass |
| 2026-10-08 | iOS fallback no longer skips the simulator guards; evidence host has no hook-bypassing fallback; designer memory moved to user scope so it survives worktree removal | `references/tools.md`, `agents/android-m3-expressive-designer.md` | Codex review of PR 92, fifth pass |
| 2026-10-08 | Delivery records the merge SHA with `gh issue comment` (the PR's `Fixes #<n>` already closes the issue); Compose/UI changes run the AGENTS.md UI-polish command list | `skills/rhymeai-orchestrator`, `references/tools.md`, `agents/rhymeai-verifier.md`, `CLAUDE.md` | Codex review of PR 92, sixth pass |
| 2026-10-08 | UI-polish-pass tasks stay on `chore/ui-polish-2026-05`; visual changes attach before/after screenshots to the PR | `skills/rhymeai-pr-evidence` | Codex review of PR 92, seventh pass |
| 2026-10-08 | UI-polish-pass tasks branch from and target `chore/ui-polish-2026-05` in the orchestrator gate too, with the pass's full commit-scope list | `skills/rhymeai-orchestrator`, `skills/rhymeai-pr-evidence` | Codex review of PR 92, eighth pass |
| 2026-10-08 | Designer consultation in the scope phase is read-only and edits only in a given worktree; merge cleanup removes the worktree before deleting the branch explicitly | `agents/android-m3-expressive-designer.md`, `skills/rhymeai-orchestrator`, `skills/rhymeai-pr-evidence` | Codex review of PR 92, ninth pass |
| 2026-10-08 | The orchestrator creates the task worktree and branch before delegating implementation | `skills/rhymeai-orchestrator` | Codex review of PR 92, tenth pass |
