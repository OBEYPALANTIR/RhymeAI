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

Pairing slots and actual first-pass sampler seeds: {'7000': {'candidate': 8000, 'incumbent': 7000}, '7001': {'candidate': 8001, 'incumbent': 7001}, '7002': {'candidate': 8002, 'incumbent': 7002}}. Retries add 10000 to the corresponding arm's seed.

G1: 60 new original drafts; 480 suggestions, 180 passage rewrites, 360 word rewrites, 120 synonym requests.
Kotlin prompt-byte parity: 1140/1140. Overlapping 8-gram lines: 0 across 1447 files in 13 training pools.
See benchmark.json, parity.jsonl, inputs.json, prompts.json and overlap-final.json for hashes and inventory.

95% paired percentile intervals use 20,000 bootstrap resamples of whole songs (seed 20261014), retaining all tasks, prompts, lines and sampler seeds inside each song cluster.
A [0, 0] null interval contains zero; equality supplies no evidence of a strict improvement.

## pooled

| Metric | Candidate / incumbent; delta [95% CI] |
|---|---|
| full_six | 99.93% / 99.93%; delta +0.00 pp [-0.21, +0.21] |
| retry | 19.65% / 21.11%; delta -1.46 pp [-4.31, +1.32] |
| level_pass | 51.63% / 54.21%; delta -2.58 pp [-4.94, -0.19] |
| template_repetition | 0.04% / 0.12%; delta -0.08 pp [-0.20, +0.00] |
| rewrite_passage | 97.22% / 97.22%; delta +0.00 pp [-1.85, +1.85] |
| rewrite_word | 97.59% / 97.41%; delta +0.19 pp [-0.93, +1.20] |
| synonyms | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |

Suggestion errors: {'candidate': 0, 'incumbent': 0}; categories: {'candidate': {'6': 1439, 'accepted': 1}, 'incumbent': {'6': 1439, 'accepted': 1}}.
Verdicts: G2=PASS, G3=FAIL, G4=PASS, G5=PASS; point-estimate agreement: G2=yes, G3=yes, G4=yes, G5=yes

| Judge scope | Wins / losses / ties | Exact two-sided sign p | Net preference [95% CI] |
|---|---|---|---|
| all | 299 / 296 / 215 | 0.934662 | 36.91% / 36.54%; delta +0.37 pp [-4.73, +5.47] |
| level:Complex | 63 / 56 / 61 | 0.582494 | 35.00% / 31.11%; delta +3.89 pp [-3.83, +11.86] |
| level:Moderate | 60 / 67 / 53 | 0.594615 | 33.33% / 37.22%; delta -3.89 pp [-16.67, +9.20] |
| level:Simple | 69 / 61 / 50 | 0.53942 | 38.33% / 33.89%; delta +4.44 pp [-7.47, +16.94] |
| rhyme_type:NEAR | 49 / 41 / 45 | 0.460792 | 36.30% / 30.37%; delta +5.93 pp [-5.93, +17.83] |
| rhyme_type:NEW_SOUND | 50 / 57 / 28 | 0.562093 | 37.04% / 42.22%; delta -5.19 pp [-18.52, +8.15] |
| rhyme_type:PERFECT | 47 / 44 / 44 | 0.834081 | 34.81% / 32.59%; delta +2.22 pp [-12.12, +17.36] |
| rhyme_type:SLANT | 46 / 42 / 47 | 0.749329 | 34.07% / 31.11%; delta +2.96 pp [-10.85, +17.04] |

## 7000

| Metric | Candidate / incumbent; delta [95% CI] |
|---|---|
| full_six | 100.00% / 99.79%; delta +0.21 pp [+0.00, +0.62] |
| retry | 19.58% / 22.71%; delta -3.12 pp [-7.08, +0.83] |
| level_pass | 51.88% / 54.57%; delta -2.69 pp [-6.94, +1.46] |
| template_repetition | 0.04% / 0.10%; delta -0.06 pp [-0.14, +0.03] |
| rewrite_passage | 95.56% / 96.67%; delta -1.11 pp [-4.44, +1.67] |
| rewrite_word | 96.67% / 97.50%; delta -0.83 pp [-2.78, +1.39] |
| synonyms | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |

Suggestion errors: {'candidate': 0, 'incumbent': 0}; categories: {'candidate': {'6': 480}, 'incumbent': {'6': 479, 'accepted': 1}}.
Verdicts: G2=FAIL, G3=FAIL, G4=FAIL, G5=PASS; point-estimate agreement: G2=yes, G3=no, G4=yes, G5=yes

| Judge scope | Wins / losses / ties | Exact two-sided sign p | Net preference [95% CI] |
|---|---|---|---|
| all | 94 / 105 / 71 | 0.478491 | 34.81% / 38.89%; delta -4.07 pp [-14.13, +6.05] |
| level:Complex | 15 / 22 / 23 | 0.324009 | 25.00% / 36.67%; delta -11.67 pp [-32.76, +10.53] |
| level:Moderate | 21 / 22 / 17 | 1 | 35.00% / 36.67%; delta -1.67 pp [-22.41, +19.61] |
| level:Simple | 21 / 23 / 16 | 0.880396 | 35.00% / 38.33%; delta -3.33 pp [-23.21, +16.07] |
| rhyme_type:NEAR | 13 / 16 / 16 | 0.711071 | 28.89% / 35.56%; delta -6.67 pp [-27.91, +13.95] |
| rhyme_type:NEW_SOUND | 17 / 18 / 10 | 1 | 37.78% / 40.00%; delta -2.22 pp [-27.91, +24.44] |
| rhyme_type:PERFECT | 15 / 18 / 12 | 0.728332 | 33.33% / 40.00%; delta -6.67 pp [-30.61, +18.60] |
| rhyme_type:SLANT | 12 / 15 / 18 | 0.701108 | 26.67% / 33.33%; delta -6.67 pp [-31.91, +19.05] |

## 7001

| Metric | Candidate / incumbent; delta [95% CI] |
|---|---|
| full_six | 99.79% / 100.00%; delta -0.21 pp [-0.62, +0.00] |
| retry | 18.12% / 17.92%; delta +0.21 pp [-3.96, +4.37] |
| level_pass | 52.83% / 53.06%; delta -0.22 pp [-4.42, +4.04] |
| template_repetition | 0.04% / 0.07%; delta -0.03 pp [-0.14, +0.06] |
| rewrite_passage | 97.78% / 99.44%; delta -1.67 pp [-3.89, +0.00] |
| rewrite_word | 98.33% / 98.06%; delta +0.28 pp [-0.83, +1.39] |
| synonyms | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |

Suggestion errors: {'candidate': 0, 'incumbent': 0}; categories: {'candidate': {'6': 479, 'accepted': 1}, 'incumbent': {'6': 480}}.
Verdicts: G2=PASS, G3=FAIL, G4=PASS, G5=PASS; point-estimate agreement: G2=yes, G3=no, G4=yes, G5=yes

| Judge scope | Wins / losses / ties | Exact two-sided sign p | Net preference [95% CI] |
|---|---|---|---|
| all | 86 / 104 / 80 | 0.217356 | 31.85% / 38.52%; delta -6.67 pp [-16.04, +2.26] |
| level:Complex | 20 / 17 / 23 | 0.742829 | 33.33% / 28.33%; delta +5.00 pp [-14.29, +24.19] |
| level:Moderate | 16 / 28 / 16 | 0.0961418 | 26.67% / 46.67%; delta -20.00 pp [-42.31, +3.39] |
| level:Simple | 25 / 17 / 18 | 0.279956 | 41.67% / 28.33%; delta +13.33 pp [-8.93, +35.71] |
| rhyme_type:NEAR | 16 / 13 / 16 | 0.711071 | 35.56% / 28.89%; delta +6.67 pp [-19.05, +31.11] |
| rhyme_type:NEW_SOUND | 16 / 23 / 6 | 0.336784 | 35.56% / 51.11%; delta -15.56 pp [-42.55, +11.11] |
| rhyme_type:PERFECT | 15 / 10 / 20 | 0.424356 | 33.33% / 22.22%; delta +11.11 pp [-11.11, +33.33] |
| rhyme_type:SLANT | 14 / 16 / 15 | 0.855536 | 31.11% / 35.56%; delta -4.44 pp [-25.58, +17.39] |

## 7002

| Metric | Candidate / incumbent; delta [95% CI] |
|---|---|
| full_six | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |
| retry | 21.25% / 22.71%; delta -1.46 pp [-6.04, +3.12] |
| level_pass | 50.17% / 55.00%; delta -4.83 pp [-8.65, -0.97] |
| template_repetition | 0.04% / 0.19%; delta -0.15 pp [-0.49, +0.04] |
| rewrite_passage | 98.33% / 95.56%; delta +2.78 pp [-0.56, +6.67] |
| rewrite_word | 97.78% / 96.67%; delta +1.11 pp [-1.39, +3.61] |
| synonyms | 100.00% / 100.00%; delta +0.00 pp [+0.00, +0.00] |

Suggestion errors: {'candidate': 0, 'incumbent': 0}; categories: {'candidate': {'6': 480}, 'incumbent': {'6': 480}}.
Verdicts: G2=PASS, G3=PASS, G4=FAIL, G5=PASS; point-estimate agreement: G2=yes, G3=yes, G4=yes, G5=yes

| Judge scope | Wins / losses / ties | Exact two-sided sign p | Net preference [95% CI] |
|---|---|---|---|
| all | 119 / 87 / 64 | 0.0305337 | 44.07% / 32.22%; delta +11.85 pp [+2.72, +21.26] |
| level:Complex | 28 / 17 / 15 | 0.135156 | 46.67% / 28.33%; delta +18.33 pp [-1.59, +36.67] |
| level:Moderate | 23 / 17 / 20 | 0.429591 | 38.33% / 28.33%; delta +10.00 pp [-10.94, +31.15] |
| level:Simple | 23 / 21 / 16 | 0.880396 | 38.33% / 35.00%; delta +3.33 pp [-17.46, +25.00] |
| rhyme_type:NEAR | 20 / 12 / 13 | 0.215327 | 44.44% / 26.67%; delta +17.78 pp [-6.52, +42.56] |
| rhyme_type:NEW_SOUND | 17 / 16 / 12 | 1 | 37.78% / 35.56%; delta +2.22 pp [-23.26, +26.67] |
| rhyme_type:PERFECT | 17 / 16 / 12 | 1 | 37.78% / 35.56%; delta +2.22 pp [-26.00, +29.55] |
| rhyme_type:SLANT | 20 / 11 / 14 | 0.149613 | 44.44% / 24.44%; delta +20.00 pp [-7.50, +47.62] |

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
Incremental judge API cost: $0.00. Included ChatGPT subscription; unchanged native credit balance around every batch. Token usage: {'input_tokens': 2675211, 'reasoning_output_tokens': 1780, 'output_tokens': 78017, 'cached_input_tokens': 658688, 'cache_write_input_tokens': 0}.
The template metric counts shown line pairs with identical first three content tokens, divided by all shown line pairs; lower is better.
This captures desktop llama-server inference through Android Kotlin builders, GenerationBoundary and validators. JNI execution and physical-device performance remain manual G7.

candidate: `/Volumes/Untitled/models/rhymeai/students-v21-20261006/E2B/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf`
SHA-256: `4cfffebcb0b96e154d963de5d90ed63962d0bcd9e77ab9fec38314257870e6a5`.

incumbent: `/Volumes/Untitled/models/rhymeai/students-v21-20261006/E2B/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf`
SHA-256: `4cfffebcb0b96e154d963de5d90ed63962d0bcd9e77ab9fec38314257870e6a5`.
