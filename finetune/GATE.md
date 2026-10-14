# Frozen on-device model gate v1

Run from the repository root:

```sh
python3 finetune/gate/run_gate.py --candidate /path/to/candidate.gguf --out /path/to/new-run
# Optional: --incumbent /another/location/of/the/shipped/gguf
# Null sampling-noise control (candidate is also the shipped GGUF):
python3 finetune/gate/run_gate.py --candidate /path/to/shipped.gguf --candidate-seed-offset 1000 --out /path/to/null-noise
```

The command freezes/validates inputs, exports exact Android Kotlin prompts,
starts one owned llama-server at a time, generates both arms, judges the shown
outputs, and writes `report.md` and `summary.json` with PASS/FAIL for G1-G6.
A scientific FAIL is a completed run; an execution failure exits nonzero and
writes an incomplete report. Repeating the command resumes only captures whose
model, prompt, sampler, and Android source bindings match. It never trains,
downloads a model, changes a catalog, modifies app behavior, or merges a PR.

Requirements: Python 3.11+ with the existing NumPy installation, llama.cpp's
`llama-server` on PATH, the repository's offline Gradle dependencies, JDK 17+
and Android SDK, the training-pool directories below, and `codex` with an
existing ChatGPT login. `JAVA_HOME` and `ANDROID_HOME` are honored; this Mac's
Android Studio Preview JBR/SDK are the fallback. There is no API-key fallback.
Before Gradle, inference, or a new judge session, `pgrep -x "Logic Pro"` must
show it closed; otherwise defer and ask the coordinator. The runner leaves
other workers' servers untouched and terminates only its own server.

## Gate definition

All G1-G6 must pass against the shipped catalog GGUF of the same size, both v2.1 Q4_K_M:

| Size | Default path (pass `--incumbent` for E4B) | SHA-256 |
|---|---|---|
| E2B (default) | `/Volumes/Untitled/models/rhymeai/students-v21-20261006/E2B/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf` | `4cfffebcb0b96e154d963de5d90ed63962d0bcd9e77ab9fec38314257870e6a5` |
| E4B | `/Volumes/Untitled/models/rhymeai/students-v21-20261006/E4B/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf` | `6d6b7890655943a3dba1a4212f6668537503a9e085f55fbdeeb40265c5e91944` |

The runner refuses any incumbent whose bytes are not one of these shipped files.

| Gate | Required evidence and decision |
|---|---|
| G1 | Frozen, newly authored benchmark with zero overlapping 8-gram lines in the specified training pools; exact Kotlin prompt-byte parity for every prompt. |
| G2 | Suggestions: share showing all six lines at least incumbent, zero candidate errors, and retry delta 95% CI upper bound at most +5 percentage points. Each of passage rewrite, single-word rewrite and synonym pass rates must have delta CI lower bound at least -2 pp. |
| G3 | Independent blind lyric-craft judge on 150 distinct suggestion/passage prompts per seed; two orders, inconsistent judgments tied. Candidate wins overall: the song-cluster bootstrap 95% CI of net preference (win rate minus loss rate) lies entirely above zero. No suggestion level or rhyme-type stratum may have its net-preference CI entirely below zero. |
| G4 | cxlib level-rule pass rate among Android-shown suggestion lines has delta CI lower bound at least zero. Secondary evidence only: it cannot rescue G3 because the levels training data was graded by cxlib. |
| G5 | Template-repetition delta CI upper bound at most zero. Lower repetition is better. |
| G6 | G2-G5 each pass separately on seeds 7000, 7001 and 7002, as well as pooled. |
| G7 - manual | Physical Pixel: model loads; first validated suggestion within 10 s warm / 30 s cold; Stop works. Recorded, not run here. |
| G8 - manual | Tyler blind-reads at least 30 paired outputs, including 20 Complex, and prefers the candidate. Recorded, not run here. |

The six-line yield criterion uses the observed paired difference, with its CI
reported. The other CI rules are the conservative bounds above, not a claim
that an insignificant loss establishes equivalence. No metric is rounded
before a decision. Undefined denominators and missing evidence cannot pass.

## Frozen benchmark and contamination audit

`gate/benchmark-songs.jsonl` contains 40 original drafts written for this gate
on 2026-10-14, with no owner/private lyrics or copied repository/artifact lyrics.
The same frozen text is published at
`~/.agents/artifacts/2026-10-14/rhymeai-gate-v1/benchmark-songs.jsonl` so the data
worker can exclude it. The songs must never become training data.

`build.py` deterministically expands them to 480 inputs: 320 suggestions across
all 12 level/rhyme cells (Simple, Moderate, Complex x PERFECT, NEAR, SLANT,
NEW_SOUND); 60 passage rewrites (20 each REPHRASE, PUNCH_UP, HARDER_RHYME);
60 single-word rewrites (all actions, 30 with previously rejected words); and
40 synonym requests. Verse, chorus, bridge and unmarked sections occur with
and without a separate first chorus. NEW_SOUND means no target rhyme line.

`frozen.json` pins the song bytes, complete generated inputs, complete prompt
export, and each prompt's input/inner/envelope hashes. Runs write the readable
inputs and exact Kotlin-exported prompt bytes to `inputs.json` and
`prompts.json`. A changed builder or fixture fails the frozen hash comparison;
updating a benchmark is a new reviewed version, never a silent refresh.
Output-dependent rejected-word retry prompts are also built by Kotlin and
their actual bytes/hashes are retained per inference pass.

The overlap checker normalizes case, punctuation and apostrophes, then checks
contiguous eight-word sequences **within each decoded line**. It scans every
JSON/JSONL file and Python string pool recursively in the v3 and levels packages
(a superset of all contexts/train/val/test and levels inputs), plus literals in
`finetune/data/seed_songs.py` and `finetune/eval/cases.py`. Missing required
directories are errors. It records every scanned file hash and all matching
benchmark song/line IDs, including duplicates across files.

- `~/.agents/artifacts/2026-10-07/rhymeai-teacher-data-v3/`
- `~/.agents/artifacts/2026-10-08/rhymeai-colab-package-levels/`
- `~/.agents/artifacts/2026-10-14/rhymeai-teacher-data-v4/` when present

The scan runs again after generation and judging, to include newly arrived v4
data. Original authorship plus exclusion and these inventories establish the
RhymeAI fine-tuning holdout; they do not claim knowledge of arbitrary external
models' training histories.

## Production contract and uncertainty

`LocalModelGateTest` promotes the 2026-10-13 `CurrentAndroidReplayTest`. It skips
with JUnit Assume before accessing files/network when `RHYMEAI_GATE_INPUT` is
unset. Production `AIService` builds all prompts and handles suggestion
stream filtering/retry, rewrite cleanup, contextual word acceptance and synonym
parsing. The test mirrors the private word-rewrite two-attempt transport loop
and calls its real Kotlin helpers; it does not substitute Python validators.
Raw server chunks pass through production `GenerationBoundary` (4096 UTF-16
units, 120-second deadline), then the real suggestion line budgets and
retry-once/show-3-5 rule. Each saved capture is replayed offline and compared
to its live result, including retry prompts and errors.

Temperature .7, top-k 40, top-p .95, min-p .05, repeat penalty 1, last_n 64,
unbounded n_predict within Android's limits; full sampler settings are saved.
The second attempt uses the seed plus 10000, fixed before observation. By default
both arms receive the same seeds. `--candidate-seed-offset` shifts only the
candidate's sampler seeds, including retries, for a null sampling-noise control.
Nonzero offsets must produce disjoint initial/retry seeds across arms; offset
1000 gives candidate 8000/8001/8002 versus incumbent 7000/7001/7002. Reports retain
7000/7001/7002 as pairing slots and show both actual seed sets. The offset is
bound in generation metadata, raw request audits and provenance; thresholds
and prompt selection do not change. The server has context 2048, parallelism 1; the
GGUF template and BOS/token budget are checked for **every** frozen prompt.
Only Gemma 4 envelopes that match this production contract are accepted.

This is desktop model inference through real Android Kotlin, not Android JNI
execution or physical-device latency. G7 is still required. Raw chunks,
rejections, shown lines, retries, timings, errors, source/model hashes, server
commands/properties, Gradle logs and JUnit XML remain in the output directory.

Paired ratio confidence intervals use 20,000 percentile bootstrap resamples
with seed 20261014. The resampling unit is the original song, keeping its
multiple prompts, three sampler seeds and shown lines together. Reports also
show each seed separately. Ratios use total numerators/denominators, not the
mean of per-request ratios. Judgments repeat each prompt over three seeds and
each song over several prompts, so they are not independent: G3 decides on the
song-cluster net-preference CI. The exact sign test (`run_naturalness.sign_test_p`,
unit = judged prompt/seed pair) is reported as descriptive only; on clustered
rows it overstates significance. Stratum tests are unadjusted and therefore
conservative about blocking a candidate.

The mechanical diversity metric is the share of unordered pairs in a shown
suggestion set whose first three content tokens match. Tokens are lowercase
words after a fixed function-word list; lines with fewer than three content
tokens cannot match. Denominators include all shown pairs. It detects repeated
openings with different end words; it is not a complete semantic diversity
measure. The independent craft judge also considers repetition.

`cxlib.py` and `phonetics.py` contain the unchanged grading dependency closure
from the prior levels package, with original file hashes recorded in their
headers. Unused teacher/server code was omitted. Only already-shown lines are
graded, and a dropped line is an error.

## Independent judge and cost

The runner uses **gpt-6-astra**, low reasoning effort, through non-interactive
`codex exec` using this Mac's existing ChatGPT subscription login. It refuses
API-key login and checks native allowance and credit balance around each batch.
An unavailable meter, exhausted allowance, changed account or credit debit stops
the run so an unknown charge cannot be reported as zero. Incremental
usage-billed API cost is **$0** when the native balance remains unchanged; the pre-existing
subscription is not allocated to this run. Token usage is recorded. No paid
fallback is configured; ask the coordinator before exceeding the $25 baseline
budget.

The rubric and consolidation rule come directly from `eval/run_naturalness.py`
(PR #97). The judge sees only prompt text, shown output and randomized L/R
labels. It sees no model names, level scores, gate thresholds or answer key.
Two separate orders are shuffled independently and judged in fresh sessions;
tools are forbidden and any observed tool use invalidates the batch. A win
requires agreement after reversing the swapped order; inconsistent judgments
are ties. Invalid or missing verdicts fail, never become convenient ties.
Each seed has 120 suggestions (10 per level/rhyme cell) and 30 passages (10 per
action), selected by fixed input-ID hashes before observing any output.

Both null controls independently generate both arms from the same v2.1 bytes.
The identical-seed control checks judge consistency: it must not pass G3 on
equality, and a deterministic CI of [0, 0] includes zero without measuring
sampling variation. The disjoint-seed control measures sampling noise; inspect
its sign test for a spurious significant win and its yield, level and diversity
CIs for zero coverage. Declare its offset before generation, retain every
result, and never search seeds until a desired null outcome appears. Both
controls use the full blind, swapped judging protocol.

## Verification

```sh
cd finetune
python3 -m unittest discover -s eval -t .
python3 -m unittest discover -s gate -t .
cd ../android
# First verify Logic Pro is closed, and leave RHYMEAI_GATE_INPUT unset.
./gradlew :app:testDebugUnitTest
```

Tests cover overlap normalization/decoding, ratio bootstrap math, template
repetition and verdict boundaries. Normal offline unit tests never start an
inference server. The baseline output directories are `rhymeai-gate-v1/levels`
and `rhymeai-gate-v1/null` (identical seeds), with the sampling-noise control in
`rhymeai-gate-v1/null-noise`; no training or manual G7/G8 run is included.
