#!/usr/bin/env bash
# Phase 3 step 3 — LoRA adapter -> quantized GGUF, WITHOUT unsloth's exporter.
#
# Why the detour: unsloth's model.save_pretrained_gguf() on Gemma 4 E2B/E4B
# hits bug #6808 — llama.cpp's convert_hf_to_gguf chokes on the merged
# multimodal checkpoint ("Can not map tensor 'audio_tower.layers.0....'").
# Our LoRA is text-only (train_lora.py freezes vision, never touches audio),
# so we skip the merged-HF route entirely:
#
#   1. convert_lora_to_gguf.py   adapter (safetensors) -> adapter GGUF (F16)
#   2. llama-export-lora         merge adapter into the BF16 base GGUF
#   3. llama-quantize            merged BF16 -> Q4_K_M
#
# Base GGUF: download the full-precision file from unsloth's GGUF repos —
#   huggingface-cli download unsloth/gemma-4-E2B-it-GGUF gemma-4-E2B-it-BF16.gguf
#   huggingface-cli download unsloth/gemma-4-E4B-it-GGUF gemma-4-E4B-it-BF16.gguf
# (the repos ship BF16, not F16; E2B BF16 is ~9.3 GB).
#
# Quantization note: the app currently ships unsloth's UD-Q4_K_XL ("Unsloth
# Dynamic" per-layer mixed quant, e.g. gemma-4-E2B-it-UD-Q4_K_XL.gguf,
# 3.18 GB). llama-quantize cannot reproduce the UD recipe, so this script
# emits plain Q4_K_M (3.11 GB for E2B) — marginally smaller, marginally less
# accurate at the tails. The before/after gate (finetune/eval/run_eval.py)
# measures the tuned Q4_K_M against the shipped UD-Q4_K_XL baseline, so any
# quant-recipe delta is included in the scorecard rather than hidden.
#
# Requirements (local Mac is fine):
#   - brew install llama.cpp                     (llama-export-lora, llama-quantize)
#   - git clone https://github.com/ggml-org/llama.cpp  (for convert_lora_to_gguf.py)
#     python3 -m pip install -r llama.cpp/requirements/requirements-convert_lora_to_gguf.txt
#
# Usage:
#   finetune/train/export_gguf.sh \
#       --adapter out/e2b-lora-v1/adapter \
#       --size E2B \
#       --base-gguf ~/models/gemma-4-E2B-it-BF16.gguf \
#       --llama-cpp ~/src/llama.cpp \
#       --out artifacts/gemma-local-models
#
#   Same for E4B: --size E4B --base-gguf .../gemma-4-E4B-it-BF16.gguf
set -euo pipefail

ADAPTER_DIR=""
SIZE=""                     # E2B | E4B (names outputs + picks default base id)
BASE_GGUF=""                # path to gemma-4-<SIZE>-it-BF16.gguf
LLAMA_CPP_DIR=""            # llama.cpp checkout (for convert_lora_to_gguf.py)
OUT_DIR="finetune/train/out/gguf"
BIN_DIR="$(dirname "$(command -v llama-quantize || echo /opt/homebrew/bin/llama-quantize)")"
QUANT="Q4_K_M"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --adapter)   ADAPTER_DIR="$2"; shift 2 ;;
        --size)      SIZE="$2"; shift 2 ;;
        --base-gguf) BASE_GGUF="$2"; shift 2 ;;
        --llama-cpp) LLAMA_CPP_DIR="$2"; shift 2 ;;
        --out)       OUT_DIR="$2"; shift 2 ;;
        --quant)     QUANT="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

[[ -n "$ADAPTER_DIR" && -n "$SIZE" && -n "$BASE_GGUF" && -n "$LLAMA_CPP_DIR" ]] || usage
[[ "$SIZE" == "E2B" || "$SIZE" == "E4B" ]] || { echo "--size must be E2B or E4B" >&2; exit 1; }
[[ -d "$ADAPTER_DIR" ]] || { echo "adapter dir not found: $ADAPTER_DIR" >&2; exit 1; }
[[ -f "$BASE_GGUF" ]]   || { echo "base GGUF not found: $BASE_GGUF" >&2; exit 1; }

CONVERT_SCRIPT="$LLAMA_CPP_DIR/convert_lora_to_gguf.py"
[[ -f "$CONVERT_SCRIPT" ]] || { echo "missing $CONVERT_SCRIPT (clone llama.cpp)" >&2; exit 1; }

EXPORT_LORA="$BIN_DIR/llama-export-lora"
QUANTIZE="$BIN_DIR/llama-quantize"
for tool in "$EXPORT_LORA" "$QUANTIZE"; do
    [[ -x "$tool" ]] || { echo "missing $tool (brew install llama.cpp)" >&2; exit 1; }
done

BASE_MODEL_ID="unsloth/gemma-4-${SIZE}-it"
mkdir -p "$OUT_DIR"
ADAPTER_GGUF="$OUT_DIR/gemma-4-${SIZE}-it-rhymeai-lora-adapter-F16.gguf"
MERGED_GGUF="$OUT_DIR/gemma-4-${SIZE}-it-rhymeai-merged-BF16.gguf"
FINAL_GGUF="$OUT_DIR/gemma-4-${SIZE}-it-rhymeai-${QUANT}.gguf"

echo "== 1/3 convert LoRA adapter -> GGUF (F16) =="
# --base-model-id fetches only the base config from HF (no weights needed);
# if the box is offline, replace with:  --base /path/to/unsloth/gemma-4-...-it
python3 "$CONVERT_SCRIPT" \
    --base-model-id "$BASE_MODEL_ID" \
    --outfile "$ADAPTER_GGUF" \
    --outtype f16 \
    "$ADAPTER_DIR"

echo "== 2/3 merge adapter into base BF16 GGUF =="
"$EXPORT_LORA" \
    -m "$BASE_GGUF" \
    --lora "$ADAPTER_GGUF" \
    -o "$MERGED_GGUF"

echo "== 3/3 quantize merged model -> $QUANT =="
"$QUANTIZE" "$MERGED_GGUF" "$FINAL_GGUF" "$QUANT"

echo
echo "done: $FINAL_GGUF"
echo "next: python3 finetune/eval/run_eval.py --model $FINAL_GGUF --out finetune/tuned-${SIZE}.json"
echo "cleanup hint: $MERGED_GGUF is ~full-precision sized; delete after quantizing."
