# Frozen on-device model gate

Run from the repository root:

```sh
python3 finetune/gate/run_gate.py --benchmark v2 --candidate /path/to/candidate.gguf --out /path/to/new-run
# Optional: --incumbent /another/location/of/the/shipped/gguf
# Null sampling-noise control (candidate is also the shipped GGUF):
python3 finetune/gate/run_gate.py --benchmark v2 --candidate /path/to/shipped.gguf --candidate-seed-offset 1000 --out /path/to/null-noise
```

`--benchmark v1` (the compatibility default) retains the original frozen inputs,
prompts and margins. V1 has informed six candidate evaluations; any further
adoption claim requires confirmation on v2 after candidate selection is complete.
Neither corpus may enter training or checkpoint selection. V2 has a separate
`frozen-v2.json` and `benchmark-songs-v2.jsonl`; output directories cannot mix
versions, including interrupted preparation. Every summary and report names
the benchmark version. V2 evaluation refuses to start until its null calibration
has frozen the margins.

The command freezes/validates inputs, exports exact Android Kotlin prompts,
starts one owned llama-server at a time, generates both arms, judges the shown
outputs, and writes `report.md` and `summary.json` with PASS/FAIL for G1-G6.
A scientific FAIL is a completed run; an execution failure exits nonzero and
writes an incomplete report. Repeating the command resumes only captures whose
pre-existing model, prompt, sampler, and Android source bindings match. Orphaned
raw/replay/judge results are rejected. Cached judge batches need a recorded zero
exit status and a successful terminal event; a recoverable error before success
is permitted. Starting a rerun removes old verdict files, so interrupted or failed
runs cannot retain a stale PASS. It never trains,
downloads a model, changes a catalog, modifies app behavior, or merges a PR.

Requirements: Python 3.11+ with NumPy and llama.cpp's `gguf` Python package, llama.cpp's
`llama-server` on PATH, the repository's offline Gradle dependencies, JDK 17+
and Android SDK, the training-pool directories below, and `codex` with an
existing ChatGPT login. `JAVA_HOME` and `ANDROID_HOME` are honored; this Mac's
Android Studio Preview JBR/SDK are the fallback. There is no API-key fallback.
Before Gradle, inference, or a new judge session, `pgrep -x "Logic Pro"` must
show it closed; otherwise defer and ask the coordinator. The runner leaves
other workers' servers untouched and terminates only its own server.

## Cloud CUDA lane

`cloud_lane.py` uses the existing private `rhymeai-training` bucket and pinned
llama.cpp `049326a00025d00b08cc188ed716b681e984a3f8` CUDA sm89 cache. Uploads are
content-addressed and pinned to a GCS object generation. The VM downloads that
exact generation and verifies its SHA-256 against the external-drive source
before serving. Models must be on the mounted external drive; no local copy is made.
It tries Spot L4 capacity across the five quota regions, then on-demand L4.
After a Spot preemption, use a new state/run ID with `--on-demand` and include
the earlier usage in `--spent-usd`.

```sh
python3 finetune/gate/cloud_lane.py start --state /path/to/lane/lane.json \
  --run-id unique-run-name --model /Volumes/Untitled/path/candidate.gguf \
  --model /Volumes/Untitled/path/shipped-v21.gguf --max-hours 6
# Keep this command running in another terminal; both ends bind only loopback:
python3 finetune/gate/cloud_lane.py tunnel --state /path/to/lane/lane.json --port 18080
python3 finetune/gate/run_gate.py --candidate /Volumes/Untitled/path/candidate.gguf \
  --out /path/to/new-run --server-url http://127.0.0.1:18080 --cloud-lane /path/to/lane/lane.json
python3 finetune/gate/cloud_lane.py stop --state /path/to/lane/lane.json
```

The runner selects each arm over SSH and binds the VM's actual GGUF SHA-256,
server launch identity, `/props`, CUDA backend, binary hash and pinned build.
It never starts a local server in remote mode. To select a model manually, use
`cloud_lane.py select --state ... --model ...`; supply all needed models at start.
The lane lock rejects concurrent runs or switches through the same state file.
Keep one state file per VM. The SSH tunnel exposes no public inference port and
creates no firewall rule. Existing project SSH access is used.

Candidate and incumbent must have identical backend/build bindings, including
for judging and offline reporting. Cloud runs regenerate both arms on CUDA;
Mac captures cannot pair with CUDA. Legacy Metal bindings are inferred at read
time from saved `/props`, provenance and launch commands plus the recorded
`gate/evidence/host-llama-probe-20261015.json`. The probe records the installed
binary hash, version, Metal device and historical gate GPU flags; it does not
claim that the old verbosity-3 logs observed GPU offload. Missing or conflicting
evidence fails closed. Both build and binary hash must match even when one arm
is legacy. Reports retain `legacy: true` and hashed `inferred_from` evidence;
completed captures are not rebound on disk. A continued legacy run retains that
inference marker, and new runs always bind the observed backend.
For a reused incumbent capture, `capture-reuse.json` must hash the source and
target raw/replay files and target binding. Reporting verifies every recorded
hash, identical model/prompt/sampler/source bindings and role-only capture
changes before inheriting the source backend. `inherited_from` records the
source directory, binding hash and reuse-proof hash without rewriting bindings.
Only a direct source with its own backend evidence is accepted; reuse chains
are rejected. A reuse proof for one arm does not replace the other arm's evidence.
`python3 -m gate.probe_host --commit <source-sha> --out <new-probe.json>` (from
`finetune/`) records a host probe using only `--version` and `--list-devices`;
repeat `--commit` for each historical gate source. Kotlin replay, prompt/template checks, seeds and sampling stay
the same. CUDA results do not prove Metal or physical Android performance.

For a small, unjudged smoke, supply a tiny `--dev-songs` JSONL and
`--dev-generation-only`. Both arms are generated and replayed offline again;
`generation-smoke.json` records equality. This produces **no adoption verdict**,
leaves `status.json` with `complete: false`, and spends no judge allowance.
Omit that flag on a later invocation to resume through the ordinary judge.

The VM has a hard DELETE deadline (at most six hours), an auto-delete boot disk,
and a 20-minute idle deletion timer (`--idle-minutes`, 5-60). `--spent-usd` accounts
for previous attempts; duration plus a transfer/storage reserve must fit $10.
Always run `stop`, including after failures: it deletes owned resources and
records empty instance/disk inventories, lifecycle logs and a compute cost upper
bound. Stored model/build caches remain for reuse; the cost estimate is not an
invoice. For the smoke use `--max-hours 1`. If the local gcloud storage command
fails under an unsupported Python, set `CLOUDSDK_PYTHON` to an installed supported
interpreter for these commands without changing shared configuration.

## Gate definition

All G1-G6 must pass against the shipped catalog GGUF of the same size, both v2.1 Q4_K_M:

| Size | Default path (selected from candidate GGUF metadata) | SHA-256 |
|---|---|---|
| E2B | `/Volumes/Untitled/models/rhymeai/students-v21-20261006/E2B/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf` | `4cfffebcb0b96e154d963de5d90ed63962d0bcd9e77ab9fec38314257870e6a5` |
| E4B | `/Volumes/Untitled/models/rhymeai/students-v21-20261006/E4B/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf` | `6d6b7890655943a3dba1a4212f6668537503a9e085f55fbdeeb40265c5e91944` |

The runner refuses any incumbent whose bytes are not one of these shipped files.
Before Gradle or inference, it checks `general.architecture`, `gemma4.block_count`
and `gemma4.embedding_length`: E2B is 35/1536 and E4B is 42/2560. Filenames are
ignored; a mismatched `--incumbent` or unsupported metadata shape is rejected.

## Separate development evaluation

```sh
python3 finetune/gate/run_gate.py --dev-songs /path/to/songs.jsonl --candidate /path/to/candidate.gguf --out /path/to/new-dev-run
```

DEV songs use the benchmark JSONL schema: unique `id`, `title`, `theme`, and
nonempty lyric `lines` (at least four). The supplied songs build the inputs;
they never replace or select the frozen benchmark. DEV requires zero normalized
8-gram overlap with both frozen versions and every required training pool.
The overlap audit runs again before reporting. Frozen and DEV artifacts cannot
share an output directory, including an interrupted DEV preparation.

DEV keeps the same Kotlin prompt parity, sampler, seeds, structural incumbent
check, Android replay, judge rubric and position swap. The judge selects up to
10 prompts per suggestion cell and up to 10 per passage action; a short cell
contributes every available prompt. The report and summary record distinct
judged prompt counts per cell, including zero counts. Frozen mode requires
150 v1 or 270 v2 prompt IDs per seed and all version-specific frozen hashes/counts.

The DEV manifest version is `rhymeai-dev`; the report is labeled
`DEV EVALUATION - not an adoption verdict`, and the summary verdict is always
`DEV`, even if every informational gate metric passes. A failed execution still
has no verdict. DEV results cannot authorize model adoption.

## Frozen adoption requirements

| Gate | Required evidence and decision |
|---|---|
| G1 | Frozen, newly authored benchmark with zero overlapping 8-gram lines in the specified training pools; exact Kotlin prompt-byte parity for every prompt. |
| G2 | Zero candidate suggestion errors. Non-inferiority bounds use the benchmark's calibration table below. V1: six-line display lower bound ≥ −1 pp; suggestion retry upper bound ≤ +6.5 pp; passage rewrite ≥ −8.5 pp, single-word rewrite ≥ −3.5 pp, synonyms ≥ −1 pp (lower bounds). |
| G3 | Independent blind lyric-craft judge on 150 v1 or 270 v2 distinct suggestion/passage prompts per seed; two orders, inconsistent judgments tied. Candidate wins overall: the song-cluster bootstrap 95% CI of net preference (win rate minus loss rate) lies entirely above zero. No suggestion level or rhyme-type stratum may have its net-preference CI entirely below zero. |
| G4 | cxlib level-rule pass rate among Android-shown suggestion lines: delta CI lower bound excludes the calibrated loss (v1: −5.5 pp). Secondary evidence only: it cannot rescue G3 because the levels training data was graded by cxlib. |
| G5 | Template repetition: delta CI upper bound excludes the calibrated increase (v1: +0.25 pp). Lower repetition is better. |
| G6 | Every seed (7000, 7001, 7002) agrees in direction: positive net preference, and G2/G4/G5 point estimates within the margins above. One seed's CIs are too wide to bound, so G6 checks agreement while the pooled gates carry the uncertainty. |
| G7 - manual | Physical Pixel: model loads; first validated suggestion within 10 s warm / 30 s cold; Stop works. Recorded, not run here. |
| G8 - manual | Tyler blind-reads at least 30 paired outputs, including 20 Complex, and prefers the candidate. Recorded, not run here. |

G2, G4 and G5 are non-inferiority checks: a candidate passes when its 95% CI
excludes a loss larger than the margin. Only G3 requires a demonstrated
improvement. No metric is rounded before a decision. Undefined denominators
and missing evidence cannot pass.

### V1 calibration (2026-10-14)

The first version used near-zero margins (rewrites −2 pp, cxlib 0,
repetition 0, retry +5 pp, and every G2-G5 CI on every seed). The
disjoint-seed null control (shipped v2.1 against itself, seeds 8000-8002 vs
7000-7002) failed G2, G4, G5 and G6 under that version: passage lower bound
−2.78 pp, cxlib −0.61 pp, repetition upper bound +0.08 pp, per-seed retry
bounds up to +10 pp. A model exactly as good as the incumbent could not pass.

Rule, fixed before any round-2 frozen evaluation and using only the null
run: **margin = 2 × the null's pooled 95% CI half-width, rounded up to 0.5 pp
with a 1 pp floor for yield and cxlib; repetition uses 0.05 pp steps without
the 1 pp floor.** This is a heuristic choice, not
a validated error rate. The intent is slack beyond one equal-model run's
interval width. Turning it into a pass probability would need assumptions that
`paired()`'s percentile bootstrap does not establish: a fixed-variance normal
approximation, or repeated independent null runs or simulation. This gate has
done neither. A single null run is one estimate of that width; a benchmark
revision should re-measure it.

| Check | Null pooled 95% CI (pp) | Half-width | Margin |
|---|---|---:|---:|
| Six-line display | [0, 0] | 0 | −1 pp (floor) |
| Suggestion retry | [−1.46, +4.90] | 3.18 | +6.5 pp |
| Passage rewrite pass | [−2.78, +5.56] | 4.17 | −8.5 pp |
| Word rewrite pass | [−1.67, +1.67] | 1.67 | −3.5 pp |
| Synonym pass | [0, 0] | 0 | −1 pp (floor) |
| cxlib level pass | [−0.61, +4.74] | 2.67 | −5.5 pp |
| Template repetition | [−0.15, +0.08] | 0.115 | +0.25 pp |

The margins are only as tight as this 40-song benchmark's null interval
widths. The widest is passage rewrite, with 60 prompts. These margins state
the losses the gate tolerates; they are not a measured detection limit. Adding
passage prompts should narrow the null interval, but that needs re-measuring.
Re-scoring every saved run: the disjoint null now fails only G3; the
identical-seed null fails G3 and G6; levels, E2B-v4 and E4B-v4 still fail G2,
G3 and G6.

### V2 calibration (2026-10-15)

The rule above was fixed before inspecting v2 null results. Shipped E2B v2.1
was independently generated against itself with candidate seeds 8000-8002 and
incumbent seeds 7000-7002: 3,420 prompt/seed captures per arm, all checked by
Kotlin offline replay. No candidate model touched v2 before these margins were
frozen. [`gate/frozen-v2.json`](gate/frozen-v2.json) pins the exact intervals,
margins and raw/replay capture hashes; decisions use those unrounded numbers.

| Check | Null pooled 95% CI (pp) | Half-width (pp) | Margin |
|---|---|---:|---:|
| Six-line display | [−0.2083, +0.2083] | 0.2083 | −1 pp (floor) |
| Suggestion retry | [−4.3056, +1.3194] | 2.8125 | +6 pp |
| Passage rewrite pass | [−1.8519, +1.8519] | 1.8519 | −4 pp |
| Word rewrite pass | [−0.9259, +1.2037] | 1.0648 | −2.5 pp |
| Synonym pass | [0, 0] | 0 | −1 pp (floor) |
| cxlib level pass | [−4.9425, −0.1906] | 2.3760 | −5 pp |
| Template repetition | [−0.1991, +0.0047] | 0.1019 | +0.25 pp |

More rewrite coverage narrowed this null's passage margin from 8.5 to 4 pp
and word margin from 3.5 to 2.5 pp. Retry narrowed from 6.5 to 6 pp. These are
observed widths from one control, not guaranteed sensitivity. The cxlib null
interval excludes zero on the loss side; this result is retained unchanged
and shows why one null cannot establish CI coverage or a false-pass rate.

Both completed controls pass G1/G2/G4/G5 and fail G3/G6. The
[disjoint null report](gate/evidence/v2-null-noise.md) records 299 wins,
296 losses and 215 ties: net preference +0.37 pp, song-cluster 95% CI
[−4.73, +5.47] pp, sign-test p=0.934662. The
[identical null report](gate/evidence/v2-null-identical.md) records 810 ties,
with ties in all 1,620 individual order judgments and net CI [0, 0]. Every
mechanical delta and CI is also exactly zero in that reused-capture control.
Neither control demonstrates an improvement. G7/G8 remain NOT RUN.

The disjoint run paused after 179 complete captures when another worker's
server overlapped with the owned server. The coordinator serialized the
remaining inference; the saved prefix was retained byte-for-byte and every
capture passed Kotlin offline replay. No captured result was filtered and no
device-latency claim is made. All 108 judge batches completed without tool use;
the shared ordinary-allowance meter moved from 54% to 64%, with unchanged
credits. Raw captures, bindings, audit inventories, native judge logs and
readback proofs remain under `~/.agents/artifacts/2026-10-15/rhymeai-gate-v2/`.

Known fixture quirk: the existing function-word list omits the determiners
`Each` and `One`. `gate-v2-song-21-rewrite_word-REPHRASE-1` selects `Each`;
`gate-v2-song-59-rewrite_word-REPHRASE-1` selects `One`. Their `PUNCH_UP-1`
counterparts and `gate-v2-song-21-synonyms-1` / `gate-v2-song-59-synonyms-1`
use the same words: six of 1,140 prompts. Production accepts these selections
and builds valid prompts. The coordinator explicitly retained them after
calibration to preserve the frozen inputs and capture bindings; both arms
receive the same fixtures. A future v3 selector must exclude determiners.

`gate-v2-song-30-rewrite_word-HARDER_RHYME-1` selects the line-ending `in`.
It meets the location rule, but production excludes `in` from rhyme keys
(`ProsodyAnalyzer.kt:238`) and requires nonempty keys for HARDER_RHYME
(`AIService.kt:1294`). All three seeds in both disjoint-null arms returned
no valid replacement after two calls. This one fixed failure remains in the
word-pass denominator; it is retained with the frozen inputs. A future v3
must also exclude rhyme-key stopwords from HARDER_RHYME selections.

## Frozen benchmark and contamination audit

V2 contains 60 new original drafts published for exclusion by round-4 training at
`~/.agents/artifacts/2026-10-15/rhymeai-gate-v2/benchmark-songs.jsonl`.
The repository and published bytes have SHA-256
`03edf49b827eaa5348aa42ee483a6c2a8f4841ccd42e6be14c6a047980f195ed`.
The initial audit found zero overlapping 8-gram lines across 1,447 files total:
13 training pools, repository seed/fixture sources, v1 and round-2 DEV.
`song-overlap-freeze.json` records every file hash. V2 requires the round-2 DEV
file to remain available for both audits.
All 1,140 Kotlin prompts passed byte parity: 480 suggestions (40 per level/rhyme
cell), 180 passage rewrites (60 per action), 360 word rewrites (120 per action),
and 120 synonyms. Each song supplies all actions, two word selections per action,
and two synonyms. REPHRASE/PUNCH_UP use the existing function-word exclusion
list, with the two determiner exceptions above; HARDER_RHYME selects only
line-ending words. Half of the word requests include prior rejected words.
Both versions keep the same section/context rotation and three sampler seeds.

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
JSON/JSONL file and Python string pool recursively in every training pool
(a superset of all contexts/train/val/test and package inputs), plus literals in
`finetune/data/seed_songs.py` and `finetune/eval/cases.py`. Missing required
directories are errors. It records every scanned file hash, the pool list and
all matching benchmark song/line IDs, including duplicates across files.

- Required: `~/.agents/artifacts/2026-10-07/rhymeai-teacher-data-v3/` and
  `~/.agents/artifacts/2026-10-08/rhymeai-colab-package-levels/`
- Discovered: every `~/.agents/artifacts/*/rhymeai-teacher-data*` and
  `~/.agents/artifacts/*/rhymeai-colab-package*` directory, so each new data
  version is covered without a code change

The scan runs again after generation and judging, to include newly arrived
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

To explicitly recheck a completed run after a gate-test-only source change:

```sh
cd finetune
python3 -B -m gate.recheck --out /path/to/completed-run
```

This path performs no inference or judge calls. It retains the original bindings
and verdicts, hashes the saved inputs, verifies model/prompt/sampler bytes and
unchanged production sources, and replays raw chunks through the current Kotlin
boundary and validators. It rebinds the gate-test source only after input bytes,
shown outputs, retries, decisions, errors and blinded pairs are proved unchanged.
It regenerates the report using the preserved judgments, writes `RECHECK.md` and
an explicit before/after proof under `evidence/recheck-*/`, and fails without a
verdict if equivalence cannot be proved. Legacy judge exit statuses are never
invented; this offline path preserves historical judgments, not resumable batches.

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
V1 selects 120 suggestions (10 per level/rhyme cell) and 30 passages (10 per
action) per seed. V2 scales this to 180 suggestions (15 per cell) and 90 passages
(30 per action): 270 prompts per seed, 810 paired comparisons, 1,620 order
judgments and 54 batches of 30 per comparison. Both versions select the lowest
input-ID hashes before observing any output; word/synonym prompts receive the
production acceptance checks but do not enter the lyric-craft judge. V2 reports
the distinct judged count for every cell.
This preserves the original sampling fractions within each task family. V1 and
v2 have different task weights; compare model arms within one version.

The disjoint null independently generates both arms from the same v2.1 bytes.
The v2 identical null reuses the incumbent capture for both role labels, after
full model/source/sampler/prompt binding checks and exact Kotlin offline replay;
`capture-reuse.json` retains source/target hashes and records the role-only change.
This reuse measures judge consistency, not repeat-inference determinism.
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
