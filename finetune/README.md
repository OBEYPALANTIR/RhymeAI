# finetune/ — On-Device Model Evaluation Harness

Desktop evaluation harness for the app's on-device Gemma models. It replays
the Android app's **exact** local-model prompts against a GGUF via llama.cpp
(`llama-server`) and scores the raw outputs programmatically. This is the
before/after quality gate for LoRA fine-tunes: run it on the base model to get
a baseline, run it again on the tuned model, and compare the reports.

Python 3 stdlib only — no pip dependencies.

## Layout

- `eval/prompts.py` — byte-identical ports of the Kotlin prompt builders
  (`buildLocalPrompt`, `buildLocalRewritePrompt`, `buildLocalSynonymsPrompt`,
  section directives, and the rhyme-constraint construction from
  `AIService.kt`), plus the app's on-device turn envelope (`app_prompt`,
  ported from `GGUFModelService.swift`).
- `eval/scoring.py` — CMU-dictionary phonetics ported from
  `ProsodyAnalyzer.kt` / `RhymeConstraint.kt` (rime extraction, perfect-rhyme
  check, candidate end-words, syllable counting) plus output-format validators
  mirroring the app's cleaning rules.
- `eval/cases.py` — 43 eval cases across all four local-model tasks
  (constrained/unconstrained suggestions across sections and complexities,
  passage rewrites x3 actions, single-word rewrites x3 actions including
  rejected-word retries, synonyms). All lyric contexts are original
  placeholder lyrics.
- `eval/run_eval.py` — the CLI runner.

## Running a baseline

llama.cpp must be installed (`brew install llama.cpp`; the harness expects
`/opt/homebrew/bin/llama-server`). The app's GGUFs live under
`artifacts/gemma-local-models/`.

```sh
cd /Users/tylermanring/Desktop/RhymeAI

# E2B baseline
python3 finetune/eval/run_eval.py \
  --model artifacts/gemma-local-models/gemma-4-E2B-it-UD-Q4_K_XL.gguf \
  --out finetune/baseline-E2B.json

# E4B baseline
python3 finetune/eval/run_eval.py \
  --model artifacts/gemma-local-models/gemma-4-E4B-it-UD-Q4_K_XL.gguf \
  --out finetune/baseline-E4B.json

# Smoke test on the first 5 cases only
python3 finetune/eval/run_eval.py \
  --model artifacts/gemma-local-models/gemma-4-E2B-it-UD-Q4_K_XL.gguf \
  --cases 5 --out /tmp/smoke.json
```

The runner starts `llama-server` itself (ctx 2048; temp 0.8, top-k 40,
top-p 0.95 — the mobile sampler contract), POSTs each raw pre-templated
prompt to `/completion` (which applies **no** chat template — exactly what we
want, since the prompt already carries the Gemma turn markers), scores each
response, writes the JSON report, and prints a per-task summary: format-pass
rates, rhyme-compliance tiers (perfect end-word from the candidate list /
rhymes-with-target / miss), average latency, and average output tokens. The
server is killed on exit; its log is written next to the report.

Sanity checks that don't need a model:

```sh
cd finetune
python3 -m eval.prompts   # prints one fully templated prompt per task
python3 -m eval.cases     # case counts + id uniqueness
python3 finetune/eval/run_eval.py --help   # (from repo root)
```

## ⚠️ Parity contract

`eval/prompts.py` mirrors
`android/app/src/main/kotlin/com/rhymeai/app/service/AIService.kt` (and the
enum strings in `data/model/RewriteAction.kt`, `SongSection.kt`,
`RhymeScheme.kt`) **byte for byte**. The whole point of this harness is that
the model sees exactly what the app sends. If any prompt string, section
directive, constraint sentence, or the Gemma turn template changes in the
Android (or iOS-parity) code, `eval/prompts.py` must be updated in the same
commit — otherwise baseline and post-finetune numbers measure the wrong thing.
Do not "improve" the prompts here.

Scoring parity: `eval/scoring.py` ports only what scoring needs from
`ProsodyAnalyzer.kt` / `RhymeConstraint.kt`, backed by the same shared assets
(`shared/pronunciation/cmudict-rhymeai.tsv`,
`shared/pronunciation/word-frequency.txt`). Frequency ties may order rhyme
candidates slightly differently than Kotlin's hash-map iteration, which can
affect the tail of the 12-word candidate list on rare ties — everything else
is deterministic and identical.
