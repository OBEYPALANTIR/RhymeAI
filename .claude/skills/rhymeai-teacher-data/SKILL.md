---
name: rhymeai-teacher-data
description: "How RhymeAI teacher data is generated with the local Gemma 4 31B and filtered into a training package: contexts, prompt equivalence, server guards (Logic Pro, memory floor), resumable batches, per-task and per-complexity-level filter rules, the meaning judge, packaging, blind sample. Use for: teacher data, distillation data, regenerate rows, yield, filter, judge, package, blind sample, v3, v4."
---

# RhymeAI teacher data

The students (E2B/E4B) learn only what the 31B teacher wrote under the *app's own prompt*. Data
quality, not training tricks, decides what the slider and the rhyme list do on the phone.

## Where

Pipelines live outside the repo under `~/.agents/artifacts/<date>/rhymeai-teacher-data-<version>/`
(latest: v3, 2026-10-07). Each has `README.md` with the exact commands, `app_prompt.py` (prompt
builder mirroring `finetune/eval/prompts.py` at a pinned commit under `reference/`),
`prompt_equivalence.py`, context generators, `run_teacher.py` (driver), `filter_teacher.py` /
`filter_tasks.py`, `judge_meaning.py`, `package_v3.py`, and tests.

## Non-negotiable guards

- The owner's songs (`rhymeai-owner-songs/songs.md`) are an overlap guard only: never training
  data, never copied, never uploaded.
- Load the teacher only when `pgrep -x "Logic Pro"` is empty and free+inactive memory ≥ 18 GB;
  one llama-server at a time; stop it afterwards. A multi-hour run needs the owner's go.
- Generation is resumable in batches of 200 with fsync; rerun the same command to continue.
- Nothing leaves the machine: no uploads, no git writes from the pipeline.

## Prompt equivalence first

Before generating, prove `app_prompt.py` renders byte-identical prompts to the pinned
`prompts.py` for every context at every level. Training rows store the app prompt verbatim in the
gemma4 envelope (`<|turn>user\n…<turn|>\n<|turn>model\n`), so any drift trains the wrong prompt.

## What the filter enforces (suggestions)

- Format: exactly the requested lines; no prompt echo; no copies of existing lyrics; no corpus
  6-gram overlap; no duplicate lines.
- Rhyme: end word on the allowed list or sound-verified for the rhyme type; new-sound positions
  must not rhyme with the anchor.
- Per level (measured with the eval's syllable and rhyme-tail tools): Simple 4–7 words, everyday
  vocabulary, one-syllable end preferred; Moderate 5–9; Complex 8–12 and (2+-syllable end, an
  internal rhyme, or two 3+-syllable words). Lines that miss their level are dropped; records with
  fewer than four surviving lines are dropped. Balance levels to roughly a third each.
- Fragment and forced-end-word rules: drop abstract noun-phrase fragments at Complex, stopword or
  function-word endings, and repeated content words within a line.

Rewrites and synonyms pass both the Android and iOS parsers and the 31B meaning judge (lenient
gate, strict verdict recorded on the row). Yields are low by design (30–55%); do not loosen the
judge to hit a size target; report the shortfall.

## Package

`runs/package-<v>/upload-local/inputs/`: `train.jsonl`, `val.jsonl` (via main's
`prepare_dataset.py`), `teacher-test.jsonl` and `rhymeai-eval-bundle.tar.gz` (keep byte-identical
to the previous package unless the eval builder changed on main, then rebuild from that commit),
`SHA256SUMS`. Splits are by song; overlap guard 0; no row over the token budget; deterministic
rebuild gives identical sums. Deliver a 60-item unlabeled blind sample with its key and a stats
page with per-level before/after tables. The owner blind-reads before any Colab spend.
