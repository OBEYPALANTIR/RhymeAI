---
name: rhymeai-pr-evidence
description: "How a RhymeAI change gets from a worktree to main: branch and commit conventions, the evidence the PR hook requires (path-free test summary as a secret gist, 'Run evidence' section), the Codex / CodeRabbit / Copilot review loop, rebase-merge and worktree cleanup. Use for: open a PR, evidence, gist, review findings, merge, worktree, release APK, pre-release, TestFlight."
---

# RhymeAI PR and evidence

## Branch and commits

- Work in `.agents/worktrees/<slug>/` on `claude/<slug>-<yyyymmdd>` from fresh `origin/main`.
  Exception: a task in the AGENTS.md UI polish pass cuts its branch from fresh
  `origin/chore/ui-polish-2026-05` instead, opens its PR against that branch
  (`gh pr create --base chore/ui-polish-2026-05`), so the merge and branch cleanup touch only
  the task branch, and uses the pass's Conventional Commit scopes (`feat(ui)`, `fix(ui)`,
  `refactor(ui)`, `chore(ui)`, `test(ui)`, `style(ui)`).
  Never switch, pull or edit the primary checkout.
- Commit explicit paths in logical pieces; messages describe the resulting behaviour and the
  measured effect. No attribution lines, no model names.
- Push the branch; never push main; never `--admin`; never self-approve.

## Evidence (what the PR-create hook checks)

The hook refuses a PR body without proof the change was *run*. What satisfies it:
1. A path-free test summary (no `/Users` or `/Volumes` paths, no secrets, no owner lyrics)
   uploaded as a **secret gist**. Ask the owner's OK for every upload.
2. A `## Run evidence` section in the PR body containing the gist **raw** URL
   (`https://gist.githubusercontent.com/<owner>/<id>/raw`) and the headline counts.
3. The suites that apply: Android unit (+ androidTest compile), iOS `Writers BlockTests` on the
   authorized simulator, eval unit tests; an instrumented run on the authorized emulator when a
   runtime behaviour changed; an E2B before/after through `prompts.py` when a prompt changed;
   for a Compose/UI change, the registry's `android-ui-checks` list.
4. When visual behaviour changes, before/after screenshots from the authorized emulator or
   simulator, attached to the PR (owner's OK; never committed to the repo, per `CLAUDE.md`).

PR body shape: `## Behavior` (what and why, in words), `## Validation` (suites with counts, A/B
numbers), `## Run evidence` (gist raw URL), `## Not covered` (honest gaps). Link the issue with
`Fixes #<n>` when one exists.

## Review loop

- Open with `gh pr create --body-file`, then bind it (`ccd_pr` `get_status` / `bind_pr`); the app
  watches CI, so do not poll checks yourself.
- Codex reviews on open; CodeRabbit and Copilot may too. Treat each finding as probably right:
  read the code path it names, fix on the same branch, reply on the thread with the commit, post
  a follow-up comment with the re-run counts, and request a re-review with `@codex review`.
- Merge only when CI is green on the final commit and an independent non-author verdict exists
  (a Codex "no major issues" on that commit, or a `code-reviewer` run posted to the PR).
- `gh pr merge <n> --rebase` (no `--delete-branch`: the branch is still checked out in the
  worktree, so gh would skip the local delete). Then delete the untracked evidence files, `git
  worktree remove .agents/worktrees/<slug>` without `--force`, `git branch -D <branch>` (a
  rebase-merge leaves it looking unmerged), and `git push origin --delete <branch>` if the
  remote branch still exists. Record the merge sha on the issue with `gh issue comment` (`Fixes #<n>` already closed it).

## Test builds for the owner

Debug builds are slow on device; use `assembleBenchmark` (R8, debug-signed) for perceived
performance. Publish test APKs as GitHub pre-releases tagged `android-testing-<date>-<slug>`
with the APK and its SHA-256 as assets. TestFlight needs a build-number bump and the gate script.
