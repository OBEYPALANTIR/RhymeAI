"""Merge the RhymeAI LoRA into Qwen3.5-4B and save an HF checkpoint.

Replaces convert_lora_to_gguf.py for the qwen3_5 arch, where llama.cpp cannot
apply the V-head reorder to decomposed LoRA A/B factors (NotImplementedError
in _reorder_v_heads). Merging first sidesteps the problem: the merged dense
weights reshape fine in convert_hf_to_gguf.py.

The merged checkpoint LACKS the MTP draft layer (transformers'
Qwen3_5ForConditionalGeneration doesn't model it), so after converting to
BF16 GGUF you MUST run graft_mtp.py against the stock BF16 GGUF before
quantizing — see RUNBOOK.md "Base-model bake-off variant".

Usage: merge_qwen_lora.py <adapter_dir> <out_dir>
Needs: torch, transformers, peft, accelerate, safetensors (no GPU; ~10 GB RAM)
"""
import shutil
import sys
from pathlib import Path

import torch
from peft import PeftModel
from transformers import AutoModelForImageTextToText

BASE = "Qwen/Qwen3.5-4B"
ADAPTER = Path(sys.argv[1])
OUT = Path(sys.argv[2])

print("loading base model (bf16, cpu)...")
model = AutoModelForImageTextToText.from_pretrained(
    BASE, dtype=torch.bfloat16, device_map="cpu", low_cpu_mem_usage=True)
print("applying adapter...")
model = PeftModel.from_pretrained(model, ADAPTER)
print("merging...")
model = model.merge_and_unload()
print("saving merged checkpoint ->", OUT)
model.save_pretrained(OUT, safe_serialization=True)

# convert_hf_to_gguf.py needs the tokenizer next to the weights; the adapter
# dir carries the exact files unsloth saved at train time. (AutoProcessor
# would also work but drags in PIL/torchvision for the unused vision tower.)
for name in ("tokenizer.json", "tokenizer_config.json", "chat_template.jinja"):
    shutil.copy2(ADAPTER / name, OUT / name)
print("done")
