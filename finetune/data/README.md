# finetune/data/ — Synthetic Training-Data Generation (Phase 2)

Generates verified (prompt → completion) training pairs for the four
on-device tasks — suggestions, passage rewrite, single-word rewrite, synonyms
— by sampling a randomized prompt-parameter space, querying a teacher model
over HTTP, and keeping **only** completions that fully pass the Phase 1 eval
scorers.

Python 3 stdlib only. All prompt construction, phonetics, and scoring are
imported from `finetune/eval/` — nothing prompt- or scoring-related is
duplicated here, so the parity contract in `finetune/README.md` covers this
pipeline too.

## Layout

- `seed_songs.py` — 27 original song fragments (country, hip-hop, pop, rock,
  folk, R&B; verse/chorus/bridge structures, several with repeated choruses
  for chorus-repeat contexts, three with no headers for unmarked-section
  contexts), plus theme strings and a word bank for the synonym/single-word
  tasks. All lyrics are original, written for this repo — never paste real
  lyrics in here.
- `sample_cases.py` — deterministic-seedable sampler producing case dicts in
  the eval case schema. Balance ≈ 50% suggestions / 20% passage rewrite /
  20% single-word rewrite / 10% synonyms. Randomizes song + truncation point,
  section context, rhyme type (PERFECT/NEAR/SLANT), complexity, whole-song
  flag, rewrite action, selection span, rejected-word lists, and synonym
  limits. Draws whose rhyme constraint has no candidate end-words are skipped
  (the generator redraws).
- `teacher.py` — HTTP client. `--api completion` posts the raw Gemma-templated
  prompt to llama-server `/completion` (stop `<end_of_turn>`); `--api chat`
  posts the inner user prompt to an OpenAI-compatible `/v1/chat/completions`.
  Default temperature 0.9 (diversity), retries and timeout configurable.
- `generate.py` — the CLI loop.
- `out/` — generated JSONL (git-ignored artifacts; do not commit).

## Usage

Start a teacher (pilot example: the E4B GGUF via llama.cpp):

```sh
/opt/homebrew/bin/llama-server \
  -m artifacts/gemma-local-models/gemma-4-E4B-it-UD-Q4_K_XL.gguf \
  -c 2048 -ngl 99 --port 8080
```

Then generate:

```sh
cd /Users/tylermanring/Desktop/RhymeAI
python3 finetune/data/generate.py \
  --endpoint http://127.0.0.1:8080 --api completion \
  --count 500 --seed 1 --out finetune/data/out/train-v1.jsonl
```

Each accepted record is one JSONL line:

```json
{"task": "...", "case_seed": "1-42-0", "case_params": {...},
 "user_prompt": "...", "completion": "...", "run_seed": 1, "sample_index": 42}
```

- `user_prompt` is the **inner** prompt (no `<start_of_turn>` markers) — apply
  the Gemma turn template at training time
  (`eval.prompts.gemma_instruction_prompt`).
- `completion` is the cleaned teacher text with all control-marker artifacts
  stripped.
- A rejected sample is re-drawn up to 2× with a different sub-seed; per-task
  acceptance rates are printed at the end.
- **Resume:** re-running with the same `--seed`/`--out` appends, skips
  already-emitted `sample_index`es, and keeps prior completions in the dedup
  set. Use a different `--seed` to grow the dataset with fresh samples.

Sanity checks that need no model:

```sh
python3 finetune/data/seed_songs.py     # song/bank invariants
python3 finetune/data/sample_cases.py   # 400-draw distribution + determinism
```

## The verification guarantee

Training data is **verified-correct by construction**: every stored
completion was scored by the same validators the eval harness uses
(`eval/scoring.py`, `eval/run_eval.score_case`) and fully passed —

- format rules (exact line counts, one suggestion per line, single-word
  answers, synonym limits, no numbering/quotes/markdown/labels),
- no prompt echo, no control markers, no copying existing lyric lines, no
  duplicates, rejected-word compliance,
- rhyme compliance: constrained suggestions must have **zero** miss-tier
  lines (every line's end word is a constraint candidate or rhymes with the
  target); HARDER_RHYME single-word rewrites must be a perfect rhyme for the
  selected word; synonym lists need ≥ 3 valid words.

Two cleaning/salvage steps happen **before** the final scoring pass, and both
are safe because the scorers re-validate the exact text that gets stored:

1. **Marker stripping** — teacher output frequently leads with fragments like
   `>`, `_response>`, or `<start_of_turn>model` and trails `</end_of_turn>`.
   These are stripped first (mirroring `modelPayloadPrefixPattern` /
   `markerPrefixPattern` / `markerOnlyPattern` in the app's `AIService.kt`),
   because the training completion must be the clean text.
2. **Line salvage (suggestions/synonyms only)** — if the raw list fails (e.g.
   7 lines instead of 6, or a duplicate synonym), the generator keeps only
   fully valid, non-miss, deduplicated lines; when at least the required count
   survives, the salvaged text is re-scored from scratch and must pass on its
   own. Rewrites are never salvaged — they pass whole or are rejected.

## Teacher-swap plan

1. **Local pilot (now):** Gemma E4B GGUF via llama-server `/completion` on
   this Mac. Cheap, validates the pipeline end-to-end, but acceptance rates
   are modest — the E4B is the *student*-class model, so it fails its own
   format contract often.
2. **Big-Gemma teacher (GPU box / cloud):** point `--endpoint` at a GPU
   server running a large Gemma instruct model. Prefer `--api chat` against
   an OpenAI-compatible server (vLLM etc.) — the server applies its own chat
   template and the generator sends the inner user prompt. `--api completion`
   also works for a llama-server hosting the big model. Add `--model` /
   `--api-key` if the gateway needs them. Nothing else changes: same sampler
   seeds, same scorers, same JSONL schema.
3. Expected effect: acceptance rate rises sharply with the bigger teacher;
   the verification gate stays identical, so data quality is bounded by the
   scorers, not the teacher.

Downstream (Phase 3): apply the Gemma template to `user_prompt`, train LoRA
on `completion`, then re-run `finetune/eval/run_eval.py` before/after.
