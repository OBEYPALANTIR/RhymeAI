---
name: rhymeai-orchestrator
description: "Entry point for all RhymeAI work in this repo — invoke before responding to any RhymeAI request. Coordinates the implementer, verifier and model-trainer agents to land cross-platform changes (Android, iOS, eval) with evidence, and to improve the on-device models. Triggers: feature, fix, bug, jank, prompt, rhyme, suggestions, complexity, model, teacher data, Colab, scorecard, APK, TestFlight, PR, review, merge. Also for follow-ups: re-run, update, modify, supplement, improve the previous result, redo, retry, continue, what's next."
model: inherit
---

# RhymeAI orchestrator

Coordinates the RhymeAI agents to land a change on `main` with evidence, or to improve the
on-device models. Everything the agents need to know *how* is in the skills; this file says
*who* does what and *when*.

## Execution mode: subagent

Agents are spawned with the `Agent` tool and return a report. No agent team: no phase needs two
agents talking mid-task, and the reviewer loop is external (GitHub reviewers).

## Agents

| Agent | Type | Role | Skills | Output |
|-------|------|------|--------|--------|
| rhymeai-implementer | general-purpose | cross-platform code change in an isolated worktree | rhymeai-parity, rhymeai-pr-evidence | pushed branch + evidence summary |
| rhymeai-verifier | general-purpose | cross-boundary QA: builders, fixtures, suites, model A/B | rhymeai-parity | verdict with findings |
| rhymeai-model-trainer | general-purpose | teacher data, Colab students, scorecards, catalog | rhymeai-teacher-data, rhymeai-colab-student | package / GGUF + scorecard report |
| android-m3-expressive-designer | custom | Material 3 Expressive review of Compose UI | — | design findings or UI diff |

Workers are spawned with a delegation prompt and never invoke this skill themselves (the
`CLAUDE.md` gate exempts them); the orchestrator is the only caller.

The `code-reviewer` user-level agent is the review fallback (role `reviewer`, see
`references/tools.md`) when no external reviewer posts.

## Workflow

### Phase 0: intake & triage  (always entered first — this skill is the repo entry point)
This skill runs for *every* prompt. Triage before doing anything else:
- Trivial, conversational, or outside RhymeAI (status questions, "how's it going", general
  advice) → answer directly and stop. No agents, no workspace.
- Advisory question about the code or models → read, answer, stop. Do not change anything.
- In-domain work → context check, then continue.

**Context check**: is there prior work for this request?
- An open PR or a branch under `.agents/worktrees/` for the same topic → follow-up: reuse that
  worktree and branch, resume at the phase that needs redoing.
- A GitHub issue for it (`gh issue list --state open`) → work it; otherwise create one only for
  substantive multi-step work (`gh issue create`), never for a one-line fix.
- Nothing → initial run; go to Phase 1.

**Standing gates** (apply before any phase): never edit the primary checkout; worktrees under
`.agents/worktrees/<slug>/` from fresh `origin/main` (a UI-polish-pass task starts from fresh
`origin/chore/ui-polish-2026-05` and targets that branch, per `rhymeai-pr-evidence`); no attribution lines in commits or PRs; no
secrets in code, logs, evidence or chat; the owner's private songs are test material only;
Colab units and multi-hour local 31B runs need the owner's explicit go; check
`pgrep -x "Logic Pro"` before any heavy local build or model load.

### Phase 1: scope
Read the affected code on all platforms it touches (Android `android/`, iOS `Writers Block/`,
eval `finetune/eval/`, shared fixtures `shared/fixtures/`). Decide the smallest complete change
and list every place it must reach (callers, tests, fixtures). For UI work on Compose, consult
`android-m3-expressive-designer` first.

**Branch on the kind of work:** code change → Phase 2. Model work (teacher data, student
training, scorecards) → Phase 5 first; only an *adopted* model comes back to Phase 2 as a
catalog change.

### Phase 2: implement  → `rhymeai-implementer`
Prompt it with: the issue or request, the scope list from Phase 1, the worktree path and branch
name, and the evidence required (which suites, whether a model A/B is needed). It returns the
pushed branch and a path-free evidence summary.

### Phase 3: verify  → `rhymeai-verifier`
Runs on the implementer's branch: cross-boundary comparison of the three prompt/rhyme builders
and the shared fixtures, the three suites, and the E2B before/after when a prompt changed.
Returns BLOCKING / NON-BLOCKING findings. Blocking findings go back to Phase 2 with the finding
text; at most two rounds before escalating to the owner.

### Phase 4: deliver (orchestrator-owned)
Follow `rhymeai-pr-evidence`: ask the owner's OK for the evidence gist, open the PR with the
"Run evidence" section, bind it, wait for CI plus the external reviewers, fix findings on the
same branch, re-request Codex, rebase-merge on green with an independent verdict, record the
merge on the issue when Phase 0 selected or created one (`gh issue comment <n> --body "Merged in
<merge sha>"`; the PR's `Fixes #<n>` already closes it, so run `gh issue close <n>` only if it is
still open; skip this step when there is no issue), remove the worktree.

### Phase 5: models  → `rhymeai-model-trainer`  (entered from Phase 1 for model work)
Teacher-data runs follow `rhymeai-teacher-data`; student runs follow `rhymeai-colab-student`.
The trainer reports before any step that spends Colab units or hours of local 31B time, and
the orchestrator gets the owner's go. If the scorecard says adopt, the model's catalog change
then goes through Phases 2–4 like any code change; if not, the write-up is kept and the run ends.

## Tracker coordination
GitHub Issues owns work state. Phase 0 reads it (`gh issue list --state open`, `gh issue view
<n>`); Phase 4 writes it back: `Fixes #<n>` closes the issue on merge and a
`gh issue comment` records the merge commit. Issue bodies are never
copied into the repo; the PR links the issue (`Fixes #<n>` in the PR body).

## Error handling

| Situation | Strategy |
|-----------|----------|
| Agent fails or stalls | retry once with the failure text; then do the step in the orchestrator and note it |
| CI red | read the failing job, fix on the branch; never merge red, never `--admin` |
| Reviewer finding disputed | reply with evidence on the thread; do not dismiss |
| Hook blocks a PR (missing run evidence) | add the evidence section with the gist raw URL; do not bypass |
| Logic Pro open / memory below floor | defer heavy local work, continue inspection |
| Colab disconnect | Reconnect first; the VM usually survives; re-run from the saved step |

## Test scenarios
- **Normal:** request → scope → implementer pushes branch → verifier NON-BLOCKING → PR opened
  with evidence → CI + Codex green → rebase-merge → issue closed → worktree removed.
- **Error:** verifier BLOCKING → implementer fixes → verifier clears → continue; a second
  BLOCKING round stops and reports to the owner with both findings.
