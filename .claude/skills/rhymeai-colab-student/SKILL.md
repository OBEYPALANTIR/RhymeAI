---
name: rhymeai-colab-student
description: "How a RhymeAI student (Gemma 4 E2B/E4B LoRA) is trained, exported and scored on Colab and then shipped: the colab package, Drive layout, notebook run order, the llama.cpp converter wrapper, the SAVED_OK gate, scorecard comparison, Hugging Face upload and the app catalog PR. Use for: Colab, train the student, LoRA, GGUF export, scorecard, QAT, catalog, model download link, Hugging Face revision."
---

# RhymeAI Colab student

## Package and Drive

Each run is a package under `~/.agents/artifacts/<date>/rhymeai-colab-package-<tag>/` with
`PLAN.md`/`RUNBOOK.md`, `notebooks/` (1 = E2B, 2 = E4B; 12B when needed), `build/` (builder +
tests), `data/` (reference layouts, token checks), `repo-subset/` (pinned `finetune/eval` and
tools). Inputs and notebooks are uploaded to Tyler's Drive `RhymeAI Training/<package>/`; outputs
land in `outputs/<MODEL>/`. Build the package with its builder and run its tests before upload;
the eval bundle must come from the `main` commit whose prompt builder the apps ship.

## Running

- Colab Pro: one GPU session at a time; A100 for bf16 LoRA (E2B), E4B as QLoRA. Spending units
  needs the owner's go per run.
- Drive consent popup: click through with `agents computer` on the Chrome popup (standing
  permission from the owner for this popup only). Mount timeout: extend `drive.mount` defaults;
  never wrap the function.
- `HF_TOKEN` secret is optional and may be invalid: notebooks fall back to anonymous.
- llama.cpp must be a full clone at tag b9949 (build number check); shallow clones break the
  server build.
- **Converter wrapper**: `pip install -U unsloth` pulls a transformers whose `AutoConfig` drops
  `global_head_dim` from Gemma 4's config; b9949's converters read hparams through it and fail.
  Both converters run through `raw_config_convert.py` (reads `config.json` directly). Keep it in
  every notebook.
- The GGUF must carry the Android KV placeholders (`ANDROID_KV_PAD`) and match the reference
  tensor layout; the notebook asserts this.
- A frontend disconnect does not kill the VM: click Reconnect before assuming `/content` is gone;
  the kernel namespace may be lost while files remain.
- **SAVED_OK gate**: the save cell copies GGUF, sha, metrics, adapter zip and reports to Drive
  and verifies every copy; the release cell refuses without it. Never release before SAVED_OK.

## Scoring and the decision

`tools/eval_student.py --envelope gemma4` on the 43 cases + the held-out teacher test split,
same sampler as the app. Compare against the shipped model's scorecard with the per-level
pass rates included. Adopt only on match-or-beat across the headline metrics within sampling
noise, no larger, no slower on the reference devices. Keep the losing experiment's write-up.

## Shipping

Download the GGUF with `uc?export=download&confirm=t&id=` (+ "Download anyway"), verify sha256,
store under `/Volumes/Untitled/models/rhymeai/students-<tag>/`, upload to the owner's Hugging Face
repo, then a catalog PR: pinned immutable revision, byte size and SHA-256 in
`GGUFDownloadManager.swift` and `GemmaDownloads.kt`, chat-template sha, tests that pin the
revision, and the stale-install reclaim path. Follow `rhymeai-pr-evidence`.
