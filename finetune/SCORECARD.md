# RhymeAI Gemma fine-tune v1 — before/after scorecard

Same 43-case eval (finetune/eval), same sampler contract (temp 0.8, top-k 40,
top-p 0.95, ctx 2048), scored on the quantized GGUFs. Baselines are the shipped
unsloth UD-Q4_K_XL models; tuned models are our Q4_K_M exports (quant delta is
included in the comparison).

| Task (metric)                      | E2B stock | E2B tuned | E4B stock | E4B tuned |
|------------------------------------|-----------|-----------|-----------|-----------|
| Suggestions — format pass          | 4%        | **96%**   | 4%        | **83%**   |
| Suggestions — rhyme hit            | 60%       | **92%**   | 82%       | 84%       |
| Passage rewrite — format pass      | 0%        | **100%**  | 33%       | **83%**   |
| Single-word rewrite — format pass  | 56%       | 22%*      | 11%       | **78%**   |
| Harder-rhyme = perfect rhyme       | 0/3       | 2/2       | 2/3       | 2/3       |
| Synonyms — format pass             | 0%        | 50%       | 0%        | 0%**      |

*  E2B single-word regression: empty answers / stray ">" prefix — under-trained
   task (531/5099 examples). The app's retry + fallback word maps cover it at
   runtime. v2 fix: top up rewrite_word data 3-4x, consider lower sampling temp
   for one-word tasks.
** E4B synonyms fail raw scoring only on within-list duplicates; the app's
   parser dedupes before display. v2 fix: more synonym examples + dedup-aware
   generation sampling.

Marker leakage (`_response>` etc.) is eliminated on the winning paths; the
tuned models natively speak the app's raw Gemma template (gemma-4 tokenizes it
as plain text — discovered during training, see train_lora.py comments).

Training: Colab L4, QLoRA r=16/alpha=16, 2 epochs over 4,947 verified examples.
E2B final train loss 0.253 / val 1.232; E4B train loss 0.124.
Artifacts: finetune/train/out/gguf/gemma-4-{E2B,E4B}-it-rhymeai-Q4_K_M.gguf
Reports: finetune/tuned-{E2B,E4B}.json vs finetune/baseline-{E2B,E4B}.json

---

# RhymeAI Gemma fine-tune v2 — targeted data top-up

Same eval and sampler contract as v1. v2 changed only the training data:
rewrite_word topped up 531 → 1,618 (the v1 scorecard's 3-4x prescription),
synonyms 616 → 1,232, suggestions/passage unchanged; the seed word bank was
doubled 25 → 50 words (`data/seed_songs.py`) after the v1 bank saturated the
generator's dedup. Teacher: local E4B GGUF via llama-server, same verified
pipeline. Training: Colab L4, QLoRA r=16/alpha=16, 2 epochs, 6,572 rows.
E2B train loss 0.158; E4B train loss 0.115 (epoch-1 val 1.119 / 0.826).

**Root cause found and fixed:** the v1 "E2B single-word regression" (empty
answers / stray `>` `_` prefixes) was NOT under-training — 27 training rows
carried bare `_response`/`_output` prefix lines that `generate.py`'s marker
stripping missed (it only caught the `_response>` form). E2B latched onto the
pattern; E4B shrugged it off. The regexes now catch the bare forms, the 27
rows were dropped, and E2B was retrained on the cleaned 6,572-row set.
Verified against the merged BF16 first — the artifact was in the weights,
not the quantization.

Data revision caveat: E4B v2 was trained on the pre-purge dataset (6,802 rows
including the 27 marker-polluted passage rows); only E2B was retrained on the
cleaned 6,572-row splits. E4B absorbed the pollution without symptoms, but the
next E4B retrain should use the cleaned data.

Numbers per eval run (temp-0.8 sampling makes single 43-case runs noisy —
E2B ran 3x, E4B 2x; median bolded):

| Task (metric)                      | E2B v1    | E2B v2 (3 runs)      | E4B v1  | E4B v2 (2 runs) |
|------------------------------------|-----------|----------------------|---------|-----------------|
| Suggestions — format pass          | 96%       | 92 / **100** / 100   | 83%     | 83 / **96**     |
| Suggestions — rhyme hit            | 92%       | 72 / **92** / 96     | 84%     | **93** / 96     |
| Passage rewrite — format pass      | 100%      | 83 / **83** / 100    | 83%     | **83** / 83     |
| Single-word rewrite — format pass  | 22%       | 78 / **89** / 100    | 78%     | **100** / 100   |
| Harder-rhyme = perfect rhyme       | 2/2       | 3/3 all runs         | 2/3     | 3/3 all runs    |
| Synonyms — format pass             | 50%       | **75** all runs      | 0%      | 0 / **25***     |

* E4B synonym failures remain within-list duplicates only (plus one
  repetition loop); the app's parser dedupes before display.

Both models clear the ship gate: the two targeted tasks improved sharply
(E2B word 22% → ~89%, synonyms 50% → 75%; E4B word 78% → 100%, suggestions
rhyme 84% → ~94%) with no regression outside single-run eval noise.

Artifacts: finetune/train/out/gguf-v2/gemma-4-{E2B,E4B}-it-rhymeai-Q4_K_M.gguf
(byte sizes identical to the shipped v1 files — same arch and quant — so the
app download manifests need no changes on publish).
Reports: finetune/tuned-v2-{E2B,E4B}.json (+ -run2/-run3 variance runs;
tuned-v21-E2B.json is a fourth confirming E2B run — word 9/9, suggestions
100%/91%) vs finetune/tuned-{E2B,E4B}.json (v1) and
finetune/baseline-{E2B,E4B}.json.

---

# RhymeAI Qwen3.5-4B bake-off — stock/tuned scorecard

Same 43-case eval and sampler contract, run with `--template qwen` (ChatML +
official empty-think prefill; `eval/prompts.py TEMPLATES["qwen"]`, verified
against the model's tokenizer_config chat template). Stock baseline is
unsloth's UD-Q4_K_XL; tuned is our Q4_K_M export. 3 runs each, median bolded.

| Task (metric)                      | Qwen stock (3 runs) | Qwen tuned (3 runs)  | E4B tuned v2 (median) |
|------------------------------------|---------------------|----------------------|-----------------------|
| Suggestions — format pass          | 17 / **25** / 38    | 96 / **100** / 100   | 96%                   |
| Suggestions — rhyme hit            | 55 / **62** / 64    | 98 / **99** / 100    | ~94%                  |
| Passage rewrite — format pass      | 67 / **67** / 100   | **100** all runs     | 83%                   |
| Single-word rewrite — format pass  | 89 / **100** / 100  | **100** all runs     | 100%                  |
| Synonyms — format pass             | 0 / **25** / 25     | **100** all runs     | 0/25%*                |
| Harder-rhyme = perfect rhyme       | 1-3/3               | 3/3, 2/3, 3/3        | 3/3                   |

* E4B synonym failures were within-list duplicates; tuned Qwen produces
  duplicate-free lists outright.

Tuned Qwen3.5-4B beats or ties tuned E4B v2 on every metric (128/129
case-runs passed) in a 2.5 GB artifact — vs 3.43 GB for the shipped E2B and
~5 GB for an E4B Q4_K_M — under Apache 2.0. Single-word answers are 2 tokens
at ~0.3 s. The format/rhyme leg of the bake-off ship gate is cleared;
the paired naturalness A/B vs tuned E4B remains before a base switch.

Training: Colab L4 (browser-driven), QLoRA r=16/alpha=16, 2 epochs over the
cleaned 6,572-row v2 splits templated with `prepare_dataset.py --template
qwen`. Val loss 1.543 (epoch 1) -> 1.508 (epoch 2); loss scale is not
comparable to Gemma runs (different tokenizer). Peak VRAM 5.4 GB.

Export detour (qwen3_5-specific): llama.cpp's convert_lora_to_gguf.py cannot
convert LoRA factors for this arch (V-head reorder needs a reshape that
doesn't exist for A/B factors), and the PEFT-merged checkpoint drops the MTP
draft layer, producing a GGUF llama.cpp rejects (block_count 33, 32 layers of
tensors). Working path: `merge_qwen_lora.py` -> `convert_hf_to_gguf.py` ->
`graft_mtp.py` (stock metadata + tuned tensors) -> `llama-quantize`. See
RUNBOOK.md "Base-model bake-off variant".

Artifact: finetune/train/out/gguf-qwen/qwen3.5-4B-rhymeai-Q4_K_M.gguf (2.5 GB),
SHA-256 b0c97175d90e720344f2d9fb00a3678e44e6cf479f66c9805b92bec22bc2d7e8.
Adapter: finetune/train/out/qwen4b-lora-v1-adapter (+ qwen4b-metrics.json).
Reports: finetune/tuned-qwen4b{,-run2,-run3}.json vs
finetune/baseline-qwen4b{,-run2,-run3}.json.

---

# Naturalness A/B — tuned Qwen3.5-4B vs tuned Gemma E4B v2 (2026-07-11)

Paired blind comparison via `finetune/eval/run_naturalness.py`: 30 creative
cases (suggestions + passage rewrites) x 2 samples = 60 pairs, identical
inner prompts, app sampler contract. Judge: anthropic/claude-fable-5
(third-family — neither Qwen nor Gemma — so no sibling self-preference;
schema-constrained JSON verdicts, identity stamped per judgment row). Each
pair judged twice with sides swapped; inconsistent verdicts score as ties.

| Scope            | E4B wins | Qwen wins | Ties |
|------------------|---------:|----------:|-----:|
| ALL (60 pairs)   | **37**   | 15        | 8    |
| suggestions (48) | 33       | 9         | 6    |
| passage (12)     | 4        | 6         | 2    |

Sign test (non-tie, two-sided): **p = 0.0032 — E4B leads decisively.**

Judge critique of Qwen is consistent: padded/forced rhyme endings (trailing
"though"/"ago" fillers), vaguer imagery; E4B produces more concrete,
human-sounding lines. Passage rewrites mildly favor Qwen (small n).

**Bake-off verdict: keep Gemma 4 E4B as the base.** Qwen3.5-4B cleared the
format gate (100% across tasks) and wins on memory (2.5 vs 5 GB), license
(Apache 2.0), and word-task latency, but fails the naturalness gate on the
core suggestions task, which is the product.

If the memory/license case is revisited, two credible paths before another
A/B: (1) regenerate Qwen training data with a stronger teacher (the current
set was written by tuned-E4B, so the Gemma student learns its own family's
style natively while Qwen imitates it); (2) DPO on preference pairs — the
A/B harness output (naturalness-pairs.jsonl + judgments) is already seed
preference data. A fresh off-distribution case set would also strengthen the
next verdict (current prompts share the training distribution).

Reports: finetune/naturalness-pairs.jsonl, finetune/naturalness-judgments.jsonl.

---

# Naturalness probe — STOCK Gemma 4 12B vs tuned E4B v2 (2026-07-11)

Same A/B protocol and judge as the Qwen bake-off (60 pairs, blind, both
orders, claude-fable-5). Purpose: price the prospective 16GB-device "Studio
tier" before spending a 12B training run. Note the asymmetry: stock 12B has
had NO RhymeAI fine-tune; format compliance is ignored by this eval.

| Scope            | 12B stock wins | tuned E4B wins | Ties |
|------------------|---------------:|---------------:|-----:|
| ALL (60 pairs)   | **40**         | 14             | 6    |
| suggestions (48) | 32             | 10             | 6    |
| passage (12)     | 8              | 4              | 0    |

Sign test (non-tie, two-sided): **p = 0.0005 — stock 12B out-crafts the
shipped tuned E4B decisively.**

Implications: (1) a tuned 12B (UD-Q4_K_XL, 7.4 GB) is a credible Studio tier
for 16GB+ devices — 12.9" M2 iPad Pro 1TB/2TB, M4 iPads, Macs, 12-16GB
flagships; it cannot load on 8GB devices (per-app cap ~5-6 GB). (2) Stock
12B is the obvious teacher upgrade for training-data generation (genre packs,
and the remedy the Qwen bake-off prescribed). Gemma 12B trains and exports
through the EXISTING pipeline (gemma template, export_gguf.sh path works —
no Qwen-style detour).

Reports: finetune/naturalness-12b-pairs.jsonl, finetune/naturalness-12b-judgments.jsonl.

---

# Sub-Q4 requants of tuned E4B — dead end (2026-07-11)

Motivation: a tuned E4B that fits 8GB iPads (per-app ceiling ~5-6 GB;
Q4_K_M is 5.0 GB, borderline). Findings:

- The quant ladder is nearly FLAT on E4B: IQ4_XS 4.8 GB, Q4_K_S 4.9 GB,
  Q3_K_M 4.6 GB vs Q4_K_M 5.0 GB. The per-layer-embedding tables floor the
  artifact size, so quant flavor buys at most ~0.4 GB.
- Q3_K_M additionally breaks the fine-tune: suggestions format 96% ->
  42/46/58% (3 runs), rhyme hit ~94% -> 76-85%, synonyms -> 0%. Reports:
  finetune/tuned-E4B-q3{,-run2,-run3}.json. (Plain no-imatrix Q3; a UD-style
  Q3 was not tested since the size argument had already collapsed.)

Conclusion: quantization cannot rescue the 8GB-iPad fit — the decision rests
entirely on the real per-app ceiling with the increased-memory-limit
entitlement (PocketPal pass = E4B fits; kill = undecided, needs an entitled
test build). Otherwise ship E2B on 8GB iPads.

---

# v3 dataset pollution incident — caught and purged (2026-07-12)

The first E4B-v3 fine-tune failed the harness catastrophically on
single-word rewrites (0-11% vs v2's ~89-100%; empty or ">"-prefixed
outputs), echoing the v1 marker regression. Root cause: the 12B teacher
sometimes emits EXTRA bare "<channel|>" closers through multi-line output;
the block-oriented strip regex only consumed the first block, so 75 lines
across 74 seed3 rows (0.8%) shipped with "<channel|>" line prefixes — and
the format scorers passed them (Gemma channel forms were not violations).
Small pollution, concentrated damage on short-output behavior.

Fixes: (1) generate.py now strips BOTH channel tag forms globally
(CHANNEL_TAG_RE), (2) the 74 rows were purged (v3c = 8,783 rows -> 8,519
train / 264 val), (3) polluted artifacts quarantined
(tuned-E4B-v3-POLLUTED*.json kept as evidence; GGUF deleted). E4B and 12B
are retraining on v3c. Update: residual control markers (channel/turn/think
forms) are now explicit format violations in scoring.py; the AIService.kt
stripping counterpart remains a ship-time task for the 12B tier.

Infra note for future Colab sessions: unsloth's import AUTO-DOWNGRADES
transformers to its pin (<=5.5.0), silently undoing upgrades — gemma4_unified
(12B) therefore cannot train under unsloth today. The 12B run uses plain
TRL+PEFT in a SUBPROCESS (fresh interpreter, disk-state imports), driven by
the HF-dataset command loop (cmdloop.py pattern in the training repo).

---

# v3 dataset — 12B-teacher regeneration + word-weight merge (2026-07-12/13)

All multi-line completions regenerated with STOCK Gemma 4 12B as teacher
(UD-Q4_K_XL via llama-server on the Mac), motivated by the naturalness
probes: the old E4B teacher loses to 12B on craft 14-40, so training any
model on E4B-authored prose distills craft downward. Channel-tag stripping
(see pollution incident above) is required for this teacher.

- Main pass: 7,500 attempts, seed 3; rewrite_word top-up seed 4 saturated
  fast (183/2,100 accepted, 1,453 dedup rejections — small answer space).
- Post-purge, v2's 1,618 word rows were merged in (single-word completions
  carry no prose style, so the teacher-craft concern doesn't apply); after
  dedup this adds only ~200 net rows over v3c.
- Current splits (finetune/train/out/v3/, built from
  data/out/train-v3-plus.jsonl): 8,712 train / 270 val; suggestions 44.9% /
  rewrite_word 25.2% / rewrite_passage 19.0% / synonyms 11.0%. These
  SUPERSEDE the v3c splits (8,519/264) and scan clean for all control-marker
  forms.

---

# E4B-v3c adapter (cmdloop run) — REJECTED (2026-07-13)

The e4bc adapter pushed by the Colab command loop (metrics: data=v3c-8519,
train_loss 0.130) fails the harness on short-output tasks: rewrite_word
33/44/44%, synonyms 0/0/0 (3 runs), with empty outputs and a MUTANT marker
"<end_turn>" the model invented (reports: finetune/tuned-E4B-v3c*.json;
GGUF deleted). The v3 training data scans clean for mutant markers and
duplicate synonym lists, so this is NOT data pollution. train_loss 0.130
(healthy runs: ~0.7+) indicates the loss mask collapsed to a handful of
boundary tokens — suspected train_on_responses_only misbehavior under the
session's skewed env (transformers force-upgraded for gemma4_unified vs
unsloth's <=5.5 pin). The cmdloop session was killed (cmd_11).

Plan of record:
- E4B-v3: retrain via the STANDARD Colab notebook (fresh session, stock
  unsloth env — E4B does not need the transformers upgrade) on the v3
  splits, with the supervised-token printout verified before training.
- 12B Studio tier: fresh session, TRL+PEFT subprocess path (cmd_6 pattern)
  on a CLEAN GPU — the previous attempt OOM'd because a stale 13.4GB
  process was still resident. Verify the mask by decoding supervised tokens
  of row 0 in the TRL path too.
- Gates unchanged: 43-case harness x3 + three-arm naturalness A/B
  (tuned-12B vs tuned-E4B-v3, tuned-12B vs STOCK-12B regression guard).

---

# Pipeline port onto main's Gemma 4 envelope (2026-10-10)

The July/September runs above used the legacy `<start_of_turn>` template.
The app has since moved to the Gemma 4 envelope (`<|turn>`, Oct 5) and to
complexity-aware suggestion prompts (Oct 7–8), so every dataset and adapter
listed above predates what the app now sends; regenerate before retraining.
The v3 tooling was ported onto main as follows:

- Kept: v2/v3 data fixes (bare `_response` marker forms, 50-word seed bank),
  12B export support, `run_naturalness.py` (now `--envelope-x/--envelope-y`),
  the Drive-backup and 12B notebook cells, and all reports above.
- Changed: the channel-tag fix. Instead of stripping every channel tag
  (`CHANNEL_TAG_RE`), `generate.py` cuts only the teacher's LEADING thought
  block; any other channel tag stays and the scorer rejects the sample, in
  line with main's rule that stray Gemma 4 control tokens are rejected, not
  cleaned.
- Dropped: the Qwen `--template` plumbing and export detour (bake-off lost;
  recoverable from commit `3e54522`).
