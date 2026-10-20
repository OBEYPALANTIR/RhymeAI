# Frozen model gate: FAIL

Benchmark version: rhymeai-gate-v2.

Candidate / incumbent; all differences are candidate minus incumbent.

| Gate | Verdict |
|---|---|
| G1 | PASS |
| G2 | PASS |
| G3 | FAIL |
| G4 | PASS |
| G5 | PASS |
| G6 | FAIL |
| G7 | NOT RUN - physical Pixel latency, loading and Stop |
| G8 | NOT RUN - Tyler blind read |

G3 is mandatory; cxlib cannot rescue a preference failure. G6 requires every seed's point estimates to agree: positive net preference and G2/G4/G5 within their margins.

Pairing slots and actual first-pass sampler seeds: {'7000': {'candidate': 7000, 'incumbent': 7000}, '7001': {'candidate': 7001, 'incumbent': 7001}, '7002': {'candidate': 7002, 'incumbent': 7002}}. Retries add 10000 to the corresponding arm's seed.

G1: 60 new original drafts; 480 suggestions, 180 passage rewrites, 360 word rewrites, 120 synonym requests.
Kotlin prompt-byte parity: 1140/1140. Overlapping 8-gram lines: 0 across 1447 files in 13 training pools.
See benchmark.json, parity.jsonl, inputs.json, prompts.json and overlap-final.json for hashes and inventory.

95% paired percentile intervals use 20,000 bootstrap resamples of whole songs (seed 20261014), retaining all tasks, prompts, lines and sampler seeds inside each song cluster.
A [0, 0] null interval contains zero; equality supplies no evidence of a strict improvement.

## pooled

| Metric | Candidate / incumbent; delta [95% CI] |
|---|---|
| full_six | 99.93% / 99.93%; delta +0.00 pp [+0.00, +0.00] |
| retry | 21.11% / 21.11%; delta +0.00 pp [+0.00, +0.00] |
| level_pass | 54.21% / 54.21%; delta +0.00 pp [+0.00, +0.00] |
| template_repetition | 0.12% / 0.12%; delta +0.00 pp [+0.00, +0.00] |
| rewrite_passage | 97.22% / 97.22%; delta +0.00 pp [+0.00, +0.00] |
| rewrite_word | 97.41% / 97.41%; delta +0.00 pp [+0.00, +0.00] |
| synonyms | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |

Suggestion errors: {'candidate': 0, 'incumbent': 0}; categories: {'candidate': {'6': 1439, 'accepted': 1}, 'incumbent': {'6': 1439, 'accepted': 1}}.
Verdicts: G2=PASS, G3=FAIL, G4=PASS, G5=PASS; point-estimate agreement: G2=yes, G3=no, G4=yes, G5=yes

| Judge scope | Wins / losses / ties | Exact two-sided sign p | Net preference [95% CI] |
|---|---|---|---|
| all | 0 / 0 / 810 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Complex | 0 / 0 / 180 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Moderate | 0 / 0 / 180 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Simple | 0 / 0 / 180 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:NEAR | 0 / 0 / 135 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:NEW_SOUND | 0 / 0 / 135 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:PERFECT | 0 / 0 / 135 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:SLANT | 0 / 0 / 135 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |

## 7000

| Metric | Candidate / incumbent; delta [95% CI] |
|---|---|
| full_six | 99.79% / 99.79%; delta +0.00 pp [+0.00, +0.00] |
| retry | 22.71% / 22.71%; delta +0.00 pp [+0.00, +0.00] |
| level_pass | 54.57% / 54.57%; delta +0.00 pp [+0.00, +0.00] |
| template_repetition | 0.10% / 0.10%; delta +0.00 pp [+0.00, +0.00] |
| rewrite_passage | 96.67% / 96.67%; delta +0.00 pp [+0.00, +0.00] |
| rewrite_word | 97.50% / 97.50%; delta +0.00 pp [+0.00, +0.00] |
| synonyms | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |

Suggestion errors: {'candidate': 0, 'incumbent': 0}; categories: {'candidate': {'6': 479, 'accepted': 1}, 'incumbent': {'6': 479, 'accepted': 1}}.
Verdicts: G2=PASS, G3=FAIL, G4=PASS, G5=PASS; point-estimate agreement: G2=yes, G3=no, G4=yes, G5=yes

| Judge scope | Wins / losses / ties | Exact two-sided sign p | Net preference [95% CI] |
|---|---|---|---|
| all | 0 / 0 / 270 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Complex | 0 / 0 / 60 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Moderate | 0 / 0 / 60 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Simple | 0 / 0 / 60 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:NEAR | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:NEW_SOUND | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:PERFECT | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:SLANT | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |

## 7001

| Metric | Candidate / incumbent; delta [95% CI] |
|---|---|
| full_six | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |
| retry | 17.92% / 17.92%; delta +0.00 pp [+0.00, +0.00] |
| level_pass | 53.06% / 53.06%; delta +0.00 pp [+0.00, +0.00] |
| template_repetition | 0.07% / 0.07%; delta +0.00 pp [+0.00, +0.00] |
| rewrite_passage | 99.44% / 99.44%; delta +0.00 pp [+0.00, +0.00] |
| rewrite_word | 98.06% / 98.06%; delta +0.00 pp [+0.00, +0.00] |
| synonyms | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |

Suggestion errors: {'candidate': 0, 'incumbent': 0}; categories: {'candidate': {'6': 480}, 'incumbent': {'6': 480}}.
Verdicts: G2=PASS, G3=FAIL, G4=PASS, G5=PASS; point-estimate agreement: G2=yes, G3=no, G4=yes, G5=yes

| Judge scope | Wins / losses / ties | Exact two-sided sign p | Net preference [95% CI] |
|---|---|---|---|
| all | 0 / 0 / 270 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Complex | 0 / 0 / 60 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Moderate | 0 / 0 / 60 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Simple | 0 / 0 / 60 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:NEAR | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:NEW_SOUND | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:PERFECT | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:SLANT | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |

## 7002

| Metric | Candidate / incumbent; delta [95% CI] |
|---|---|
| full_six | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |
| retry | 22.71% / 22.71%; delta +0.00 pp [+0.00, +0.00] |
| level_pass | 55.00% / 55.00%; delta +0.00 pp [+0.00, +0.00] |
| template_repetition | 0.19% / 0.19%; delta +0.00 pp [+0.00, +0.00] |
| rewrite_passage | 95.56% / 95.56%; delta +0.00 pp [+0.00, +0.00] |
| rewrite_word | 96.67% / 96.67%; delta +0.00 pp [+0.00, +0.00] |
| synonyms | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |

Suggestion errors: {'candidate': 0, 'incumbent': 0}; categories: {'candidate': {'6': 480}, 'incumbent': {'6': 480}}.
Verdicts: G2=PASS, G3=FAIL, G4=PASS, G5=PASS; point-estimate agreement: G2=yes, G3=no, G4=yes, G5=yes

| Judge scope | Wins / losses / ties | Exact two-sided sign p | Net preference [95% CI] |
|---|---|---|---|
| all | 0 / 0 / 270 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Complex | 0 / 0 / 60 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Moderate | 0 / 0 / 60 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| level:Simple | 0 / 0 / 60 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:NEAR | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:NEW_SOUND | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:PERFECT | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |
| rhyme_type:SLANT | 0 / 0 / 45 | 1 | 0.00% / 0.00%; delta +0.00 pp [+0.00, +0.00] |

## Judged prompts per cell (each seed, both positions)

| Cell | Distinct prompts |
|---|---:|
| suggestions/Simple/PERFECT | 15 |
| suggestions/Simple/NEAR | 15 |
| suggestions/Simple/SLANT | 15 |
| suggestions/Simple/NEW_SOUND | 15 |
| suggestions/Moderate/PERFECT | 15 |
| suggestions/Moderate/NEAR | 15 |
| suggestions/Moderate/SLANT | 15 |
| suggestions/Moderate/NEW_SOUND | 15 |
| suggestions/Complex/PERFECT | 15 |
| suggestions/Complex/NEAR | 15 |
| suggestions/Complex/SLANT | 15 |
| suggestions/Complex/NEW_SOUND | 15 |
| rewrite_passage/REPHRASE | 30 |
| rewrite_passage/HARDER_RHYME | 30 |
| rewrite_passage/PUNCH_UP | 30 |

## Provenance

Judge: gpt-6-astra; OpenAI via Codex ChatGPT login; 270 distinct prompts per seed, both positions.
Incremental judge API cost: $0.00. Included ChatGPT subscription; unchanged native credit balance around every batch. Token usage: {'input_tokens': 2675015, 'reasoning_output_tokens': 412, 'output_tokens': 64788, 'cached_input_tokens': 1018624, 'cache_write_input_tokens': 0}.
The template metric counts shown line pairs with identical first three content tokens, divided by all shown line pairs; lower is better.
This captures desktop llama-server inference through Android Kotlin builders, GenerationBoundary and validators. JNI execution and physical-device performance remain manual G7.

candidate: `/Volumes/Untitled/models/rhymeai/students-v21-20261006/E2B/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf`
SHA-256: `4cfffebcb0b96e154d963de5d90ed63962d0bcd9e77ab9fec38314257870e6a5`.

incumbent: `/Volumes/Untitled/models/rhymeai/students-v21-20261006/E2B/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf`
SHA-256: `4cfffebcb0b96e154d963de5d90ed63962d0bcd9e77ab9fec38314257870e6a5`.
