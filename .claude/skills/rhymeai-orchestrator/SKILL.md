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
| rhymeai-implementer | custom | cross-platform code change in an isolated worktree | rhymeai-parity, rhymeai-pr-evidence | pushed branch + evidence summary |
| rhymeai-verifier | custom | cross-boundary QA: builders, fixtures, suites, model A/B | rhymeai-parity | verdict with findings |
| rhymeai-model-trainer | custom | teacher data, Colab students, scorecards, catalog | rhymeai-teacher-data, rhymeai-colab-student | package / GGUF + scorecard report |
| android-m3-expressive-designer | custom | Material 3 Expressive review of Compose UI | — | design findings or UI diff |

All four are project agents in `.claude/agents/`. Spawn each with `subagent_type` set to its
name, so its prompt and the skills in its frontmatter load; a `general-purpose` spawn carries
neither. Workers are spawned with a delegation prompt and never invoke this skill themselves (the
`CLAUDE.md` gate exempts them); the orchestrator is the only caller.

The `code-reviewer` user-level agent is the review fallback (role `reviewer`, see
`references/tools.md`) when no external reviewer posts.

## Workflow

### Phase 0: intake & triage  (always entered first — this skill is the repo entry point)
This skill runs for *every* prompt. Triage before doing anything else:
- Trivial, conversational, or outside RhymeAI (status questions, "how's it going", general
  advice) → answer directly and stop. No agents, no workspace.
- Advisory question about the code or models → `git fetch origin`, read the code at `origin/main`
  (`git show`, `git grep`, as in Phase 1), answer, stop. Do not change anything.
- In-domain work → context check, then continue.

**Context check**: is there prior work for this request?
- An open PR, or a worktree under `.agents/worktrees/`, for the same topic → follow-up: reuse
  that worktree and branch. When a PR exists, first `git fetch origin <branch>`. If the worktree
  is missing (fresh clone, interrupted cleanup), recreate it: `git worktree prune` (drops a
  registration whose directory is gone), then `git worktree add .agents/worktrees/<slug> <branch>`
  (on a fresh clone git creates the branch tracking `origin/<branch>`). With a PR, bring the
  worktree to its head: `git -C .agents/worktrees/<slug> merge --ff-only origin/<branch>`; if that
  fails, the local branch and the PR have diverged: stop and ask the owner. Then resume at the
  phase that needs redoing.
- A GitHub issue for it (`gh issue list --state open`) → work it; otherwise create one only for
  substantive multi-step work (`gh issue create`), never for a one-line fix.
- Nothing → initial run; go to Phase 1.

**Standing gates** (apply before any phase): never edit the primary checkout; worktrees under
`.agents/worktrees/<slug>/` from fresh `origin/main` (only a task the owner assigns to the
AGENTS.md UI polish pass starts from fresh `origin/chore/ui-polish-2026-05` and targets that
branch, per `rhymeai-pr-evidence`); no attribution lines in commits or PRs; no secrets in code,
logs, evidence or chat; the owner's private songs are test material only; Colab units and
multi-hour local 31B runs need the owner's explicit go; check `pgrep -x "Logic Pro"` before any
heavy local build or model load.

### Phase 1: scope
First `git fetch origin`, then read the code as it is on the base ref (`origin/main`, or
`origin/chore/ui-polish-2026-05` for an owner-assigned UI-polish-pass task) with
`git show <ref>:<path>` and `git grep <pattern> <ref>`, or in the task worktree for a follow-up;
never scope from the primary checkout, which may be behind. Read the affected code on all
platforms it touches (Android `android/`, iOS `Writers Block/`, eval `finetune/eval/`, shared
fixtures `shared/fixtures/`). Decide the smallest complete change
and list every place it must reach (callers, tests, fixtures). For UI work on Compose, consult
`android-m3-expressive-designer` first, read-only and pointed at the same base ref: no worktree
exists yet, so it returns design findings and the implementer applies them in the task worktree.

**Branch on the kind of work:** code change → Phase 2. Model work (teacher data, student
training, scorecards) → Phase 5 first; only an *adopted* model comes back to Phase 2 as a
catalog change.

### Phase 2: implement  → `rhymeai-implementer`
On the first entry for a task, the orchestrator creates the worktree itself: `git fetch origin`,
then `git worktree add --no-track -b claude/<slug>-<yyyymmdd> .agents/worktrees/<slug> origin/main`
(an owner-assigned UI-polish-pass task uses `origin/chore/ui-polish-2026-05` as the start point).
`--no-track` keeps the base from becoming the branch's upstream; the implementer's first push is
`git push -u origin <branch>`. A correction round from Phase 3, a PR review fix or a resumed run
reuses that existing worktree and branch. Then prompt the implementer with: the issue or request,
the scope list from Phase 1, the worktree path and branch name, and the evidence required (which
suites, whether a model A/B is needed). It returns the pushed branch and a path-free evidence
summary.

### Phase 3: verify  → `rhymeai-verifier`
Runs on the implementer's branch: cross-boundary comparison of the three prompt/rhyme builders
and the shared fixtures, the three suites, and the E2B before/after when a prompt changed.
Returns BLOCKING / NON-BLOCKING findings. Blocking findings go back to Phase 2 with the finding
text; at most two rounds before escalating to the owner.

### Phase 4: deliver (orchestrator-owned)
Follow `rhymeai-pr-evidence`: build the evidence summary from the implementer's `EVIDENCE.md`
plus the verifier's verdict and suite counts (the iOS stage and the non-mutating UI checks come
only from the verifier), ask the owner's OK for the gist, open the PR with the "Run evidence"
section, hand it to the registry's `pr-watch` tool, and wait for CI plus the external reviewers.
Every fix pushed after that (a review finding or red CI) goes back through Phase 2 (the
implementer, same worktree) and Phase 3 (the verifier re-runs every check the fix can affect, its
iOS stage and UI checks included); then the PR gets a follow-up comment with the re-run counts and
Codex is re-requested. Rebase-merge, pinned to the head commit (`--match-head-commit`), only once
the verifier's latest round ran on that commit, CI is green on it and an independent verdict covers
it; when GitHub can't rebase the branch (usually because a merge from `main` resolved a conflict),
squash-merge with the same pin, as `rhymeai-pr-evidence` shows. When Phase 0 selected or created an
issue, record the merge on it (`gh issue comment <n> --body "Merged in <merge sha>"`) and run
`gh issue close <n>` if it is still open (the PR's `Fixes #<n>` closes it only when the PR merges
into the default branch); skip this step when there is no issue. Finish with the worktree and
branch cleanup in `rhymeai-pr-evidence`.

### Phase 5: models  → `rhymeai-model-trainer`  (entered from Phase 1 for model work)
Teacher-data runs follow `rhymeai-teacher-data`; student runs follow `rhymeai-colab-student`.
The trainer reports before any step that spends Colab units or hours of local 31B time, and
the orchestrator gets the owner's go. If the scorecard says adopt, the model's catalog change
then goes through Phases 2–4 like any code change; if not, the write-up is kept and the run ends.

## Tracker coordination
GitHub Issues owns work state. Phase 0 reads it (`gh issue list --state open`, `gh issue view
<n>`); Phase 4 writes it back: a `gh issue comment` records the merge commit, and the PR's
`Fixes #<n>` closes the issue when the PR merges into the default branch (otherwise Phase 4
closes it with `gh issue close`). Issue bodies are never copied into the repo; the PR links the
issue (`Fixes #<n>` in the PR body).

## Error handling

| Situation | Strategy |
|-----------|----------|
| Agent fails or stalls | retry once with the failure text; then do the step in the orchestrator and note it |
| CI red | read the failing job, fix it on the branch through Phases 2–3; never merge red, never `--admin` |
| Reviewer finding disputed | reply with evidence on the thread; do not dismiss |
| Hook blocks a PR (missing run evidence) | add the evidence section with the gist raw URL; do not bypass |
| Logic Pro open / memory below floor | defer heavy local work, continue inspection |
| Colab disconnect | Reconnect first; the VM usually survives; re-run from the saved step |

## Test scenarios
- **Normal:** request → scope → implementer pushes branch → verifier NON-BLOCKING → PR opened
  with evidence → CI + Codex green → rebase-merge (squash if it can't rebase) → issue closed →
  worktree removed.
- **Error:** verifier BLOCKING → implementer fixes → verifier clears → continue; a second
  BLOCKING round stops and reports to the owner with both findings.
