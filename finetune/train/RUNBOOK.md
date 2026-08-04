# finetune/train/ — Phase 3 LoRA Training Runbook

End-to-end procedure for fine-tuning the on-device Gemma 4 models
(E2B + E4B) on the verified Phase 2 dataset, on a **rented GPU box**
(RunPod / Lambda; one A100 or one RTX 4090 is plenty), then exporting and
re-scoring locally.

Pipeline: `prepare_dataset.py` (local) → `train_lora.py` (GPU box, both
models) → `export_gguf.sh` (local) → `finetune/eval/run_eval.py`
(local, the after-scorecard).

Key design facts (do not change casually):

- Training text is the app's exact raw Gemma template
  (`eval/prompts.gemma_instruction_prompt`), NOT the tokenizer's chat
  template — the app posts raw `<start_of_turn>` prompts to llama.cpp
  `/completion` with no template, so train == deploy byte-for-byte.
- LoRA is text-only (`finetune_vision_layers=False`, language layers only).
  This is required for the GGUF export detour that avoids unsloth bug
  #6808 (`Can not map tensor 'audio_tower.layers.0...'` when converting a
  merged multimodal checkpoint).
- Never use `model.save_pretrained_gguf(...)` for these models — that is
  the #6808 path. Always export via `export_gguf.sh`.

## 0. Prepare the dataset (local Mac)

```sh
cd /Users/tylermanring/Desktop/RhymeAI
python3 finetune/train/prepare_dataset.py \
  --in finetune/data/out/train-v1.jsonl \
  --out-dir finetune/train/out
```

Check the printed table: task mix should be roughly 50/20/20/10
(suggestions / passage rewrite / word rewrite / synonyms) in BOTH splits,
and no over-6000-char warnings. Outputs: `finetune/train/out/train.jsonl`
and `val.jsonl` (each row has a `"text"` field; extra fields are ignored by
the trainer).

## 1. Rent the box

Either works; one GPU trains both models sequentially in well under an hour
of compute.

| Provider | GPU | Approx price (on-demand) |
|---|---|---|
| RunPod | RTX 4090 24 GB | ~$0.40–0.70/hr |
| RunPod / Lambda | A100 80 GB | ~$1.20–1.90/hr |

Pick a PyTorch 2.x + CUDA 12 template. You need ~60 GB disk (base model
downloads: E2B ~11 GB + E4B ~16 GB HF weights, plus checkpoints).

## 2. Install (GPU box)

```sh
pip install -U unsloth
# unsloth pulls compatible torch/transformers/trl/peft/datasets/bitsandbytes.
python -c "import unsloth; print(unsloth.__version__)"
```

If the template's preinstalled torch fights the resolver, use unsloth's
pinned installer line from https://unsloth.ai/docs (varies by CUDA version).

## 3. Upload dataset + script

From the Mac:

```sh
scp -P <port> finetune/train/out/train.jsonl finetune/train/out/val.jsonl \
    finetune/train/train_lora.py root@<box-ip>:/workspace/
```

(RunPod: get host/port from the pod's SSH tab. Lambda: plain `ubuntu@<ip>`.)

## 4. Train both models (GPU box)

**E2B — plain LoRA** (bf16 base weights; ~8–10 GB VRAM at batch 8 / seq 2048):

```sh
cd /workspace
python3 train_lora.py \
  --base unsloth/gemma-4-E2B-it \
  --data train.jsonl --val val.jsonl \
  --out out/e2b-lora-v1
```

**E4B — QLoRA** (4-bit base; keeps peak VRAM well inside a 4090's 24 GB —
bf16 LoRA on E4B needs ~17 GB+ before activations, so 4-bit is the safe
default; on an A100 80 GB you may drop `--load-in-4bit` for a bf16 LoRA):

```sh
python3 train_lora.py \
  --base unsloth/gemma-4-E4B-it --load-in-4bit \
  --data train.jsonl --val val.jsonl \
  --out out/e4b-qlora-v1
```

Defaults: r=16 / alpha=16, 2 epochs, lr 2e-4 cosine + warmup 3%,
adamw_8bit, effective batch 16 (8×2), no packing, prompt-masked loss
(only the completion + `<end_of_turn>` is supervised — the script prints
the supervised tokens of row 0 at startup; verify they are a completion,
not the prompt).

**Expected scale** (~1.35k train rows, ~350–400 optimizer steps at
effective batch 16 for 2 epochs):

- 4090: roughly 10–25 min per model + 5–10 min model download.
- A100: similar or faster; you're paying for headroom, not speed here.
- Loss sanity: Gemma 4 E2B/E4B starting loss of **13–15 is normal**
  (documented unsloth behavior for these models) — watch the *trend* and
  the eval loss per epoch, not the absolute number.

Watch `final eval metrics:` at the end — `eval_loss` should drop epoch
over epoch; if epoch 2 eval loss rises, retrain with `--epochs 1` or
`--r 8 --alpha 8`. Add `--epochs 3` only if eval loss is still falling.

Optional: add `--save-merged` to also write merged fp16 safetensors
(~big; not needed for export).

## 5. Download artifacts (Mac)

Only the adapter dir (a few hundred MB) plus metrics are needed:

```sh
scp -P <port> -r root@<box-ip>:/workspace/out/e2b-lora-v1/adapter  finetune/train/out/e2b-lora-v1-adapter
scp -P <port> -r root@<box-ip>:/workspace/out/e4b-qlora-v1/adapter finetune/train/out/e4b-qlora-v1-adapter
scp -P <port>    root@<box-ip>:/workspace/out/e2b-lora-v1/metrics.json  finetune/train/out/e2b-metrics.json
scp -P <port>    root@<box-ip>:/workspace/out/e4b-qlora-v1/metrics.json finetune/train/out/e4b-metrics.json
```

Then **stop the pod** — billing is per-minute.

## 6. Export GGUF (local Mac)

One-time setup:

```sh
brew install llama.cpp                       # llama-export-lora, llama-quantize
git clone https://github.com/ggml-org/llama.cpp ~/src/llama.cpp
python3 -m pip install -r ~/src/llama.cpp/requirements/requirements-convert_lora_to_gguf.txt
huggingface-cli download unsloth/gemma-4-E2B-it-GGUF gemma-4-E2B-it-BF16.gguf --local-dir ~/models
huggingface-cli download unsloth/gemma-4-E4B-it-GGUF gemma-4-E4B-it-BF16.gguf --local-dir ~/models
```

(The unsloth GGUF repos ship **BF16** as the full-precision file — there is
no F16; E2B BF16 is ~9.3 GB.)

Export both:

```sh
cd /Users/tylermanring/Desktop/RhymeAI
finetune/train/export_gguf.sh \
  --adapter finetune/train/out/e2b-lora-v1-adapter --size E2B \
  --base-gguf ~/models/gemma-4-E2B-it-BF16.gguf \
  --llama-cpp ~/src/llama.cpp \
  --out finetune/train/out/gguf

finetune/train/export_gguf.sh \
  --adapter finetune/train/out/e4b-qlora-v1-adapter --size E4B \
  --base-gguf ~/models/gemma-4-E4B-it-BF16.gguf \
  --llama-cpp ~/src/llama.cpp \
  --out finetune/train/out/gguf
```

Note: output quant is **Q4_K_M**, while the shipped baselines are unsloth's
**UD-Q4_K_XL** (dynamic mixed quant that llama-quantize can't reproduce).
The eval comparison below absorbs that difference; if the tuned Q4_K_M
scorecard regresses in ways that smell like quantization (fluency, not
format), sanity-check the merged BF16 GGUF directly before blaming the LoRA.

## 7. After-scorecard (local Mac)

```sh
python3 finetune/eval/run_eval.py \
  --model finetune/train/out/gguf/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf \
  --out finetune/tuned-E2B.json

python3 finetune/eval/run_eval.py \
  --model finetune/train/out/gguf/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf \
  --out finetune/tuned-E4B.json
```

Compare against `finetune/baseline-E2B.json` / `baseline-E4B.json`:
format-pass rate and rhyme-compliance tiers per task are the headline
numbers. Ship only if the tuned model beats baseline on format-pass without
regressing rhyme misses.

## Base-model bake-off variant (Qwen3.5-4B)

The same pipeline trains `Qwen/Qwen3.5-4B` (Apache 2.0, ~2.9 GB UD-Q4_K_XL)
as a candidate replacement base. Every step takes a template/size flag; the
turn template (ChatML with the official empty-think prefill) lives in
`eval/prompts.py TEMPLATES["qwen"]` and was verified against the model's
tokenizer_config chat template.

```sh
# 0. dataset (note the separate out dir; *-qwen.jsonl copies are for Colab)
python3 finetune/train/prepare_dataset.py \
  --in finetune/data/out/train-v2.jsonl \
  --out-dir finetune/train/out/qwen --template qwen

# 4. train (GPU box; or use the notebook's "6b" section on Colab)
python3 train_lora.py --base Qwen/Qwen3.5-4B --template qwen \
  --data train.jsonl --val val.jsonl --out out/qwen4b-lora-v1

# 6. export — export_gguf.sh does NOT work here: llama.cpp's
# convert_lora_to_gguf.py can't apply the qwen3_5 V-head reorder to LoRA
# factors (NotImplementedError). Merge in PyTorch, convert, then graft the
# stock GGUF's metadata (transformers drops the MTP draft layer, so the
# converted file declares block_count 33 with only 32 layers of tensors and
# llama.cpp refuses to load it):
python3 -m venv /tmp/merge-venv
/tmp/merge-venv/bin/pip install torch transformers peft accelerate safetensors
/tmp/merge-venv/bin/python finetune/train/merge_qwen_lora.py \
  finetune/train/out/qwen4b-lora-v1-adapter /tmp/qwen4b-merged
/tmp/merge-venv/bin/python ~/src/llama.cpp/convert_hf_to_gguf.py /tmp/qwen4b-merged \
  --outfile finetune/train/out/gguf-qwen/qwen3.5-4B-rhymeai-merged-BF16.gguf \
  --outtype bf16
hf download unsloth/Qwen3.5-4B-GGUF Qwen3.5-4B-BF16.gguf --local-dir ~/models
/tmp/merge-venv/bin/python finetune/train/graft_mtp.py \
  ~/models/Qwen3.5-4B-BF16.gguf \
  finetune/train/out/gguf-qwen/qwen3.5-4B-rhymeai-merged-BF16.gguf \
  /tmp/qwen-grafted-BF16.gguf
llama-quantize /tmp/qwen-grafted-BF16.gguf \
  finetune/train/out/gguf-qwen/qwen3.5-4B-rhymeai-Q4_K_M.gguf Q4_K_M

# 7. score (stock baselines: finetune/baseline-qwen4b*.json, 3 runs)
python3 finetune/eval/run_eval.py --template qwen \
  --model finetune/train/out/gguf-qwen/qwen3.5-4B-rhymeai-Q4_K_M.gguf \
  --out finetune/tuned-qwen4b.json
```

Ship gate for the bake-off: tuned Qwen must match tuned E4B v2 on format
pass and rhyme hit (3-run median), then win or tie the paired naturalness
A/B, before it replaces the Gemma base — its memory (2.9 GB vs 5+ GB
resident) and license (Apache 2.0) advantages only matter if quality holds.

## Cost estimate

Worst-case on-demand math, both models:

- 4090 route: (setup 15 min + downloads 15 min + 2 × 25 min training +
  slack) ≈ 1.5 hr × ~$0.60/hr ≈ **$1** (call it $2 with retries).
- A100 route: same ~1.5 hr × ~$1.60/hr ≈ **$2.50** (call it $5 with
  retries/experiments, e.g. an extra r=8 and 3-epoch run of each model).
- Local costs: $0 (export + eval run on the Mac; ~25 GB of base BF16 GGUF
  downloads is the only real expense — disk and bandwidth).

Budget **$10** and you can afford several full retrain cycles.

## Artifacts hygiene

Adapters, prepared JSONL, and GGUFs land under `finetune/train/out/` —
git-ignored; do not commit (same rule as `artifacts/`). Commit only scripts,
this runbook, and the eval reports Tyler explicitly wants recorded.
