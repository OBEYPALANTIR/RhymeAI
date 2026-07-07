#!/usr/bin/env python3
"""Phase 3 step 2 — Unsloth LoRA fine-tune of Gemma 4 E2B/E4B (GPU box only).

DO NOT run on the Mac. This script targets a rented CUDA box (RunPod/Lambda,
A100 or RTX 4090) with `unsloth` installed — see finetune/train/RUNBOOK.md.

Input is the output of prepare_dataset.py: JSONL rows whose "text" field is
the FULL app-templated example

    <start_of_turn>user\n{prompt}\n<end_of_turn>\n<start_of_turn>model\n{completion}<end_of_turn>

We deliberately do NOT apply the tokenizer's own chat template
(unsloth.chat_templates.get_chat_template): the deployed app builds raw
<start_of_turn> prompts itself (AIService gemmaInstructionPrompt) and posts
them to llama.cpp /completion with no template, so training must see exactly
that surface form. Prompt tokens are masked from the loss via
train_on_responses_only with the same markers.

Text-only LoRA: `finetune_vision_layers=False` (and no audio modules are
selected) keeps the adapter strictly on the language tower — required both
for app behavior (text-only) and for the GGUF export detour in
export_gguf.sh, which sidesteps unsloth GGUF-export bug #6808 ("Can not map
tensor 'audio_tower...'" when converting the merged multimodal checkpoint).

Usage (E2B, plain LoRA on bf16 weights):
  python3 train_lora.py --base unsloth/gemma-4-E2B-it \
      --data train.jsonl --val val.jsonl --out out/e2b-lora-v1

Usage (E4B, QLoRA to fit 24 GB cards):
  python3 train_lora.py --base unsloth/gemma-4-E4B-it --load-in-4bit \
      --data train.jsonl --val val.jsonl --out out/e4b-qlora-v1
"""

from __future__ import annotations

import argparse
import json
import os

# Unsloth must be imported BEFORE transformers/trl so its patches apply.
from unsloth import FastModel  # noqa: E402
from unsloth.chat_templates import train_on_responses_only  # noqa: E402

import torch  # noqa: E402
from datasets import load_dataset  # noqa: E402
from trl import SFTConfig, SFTTrainer  # noqa: E402

# Must match prepare_dataset.py / eval.prompts.gemma_instruction_prompt.
INSTRUCTION_PART = "<start_of_turn>user\n"
RESPONSE_PART = "<start_of_turn>model\n"


def parse_args():
    parser = argparse.ArgumentParser(description="LoRA fine-tune Gemma 4 E2B/E4B with Unsloth.")
    parser.add_argument("--base", default="unsloth/gemma-4-E2B-it",
                        help="Base model (unsloth/gemma-4-E2B-it or unsloth/gemma-4-E4B-it)")
    parser.add_argument("--data", required=True, help="train.jsonl from prepare_dataset.py")
    parser.add_argument("--val", required=True, help="val.jsonl from prepare_dataset.py")
    parser.add_argument("--out", required=True, help="Output dir (adapter saved to <out>/adapter)")
    # App runtime context is 2048 (LocalModelService ctx); prepare_dataset
    # warns >6000 chars, which stays comfortably inside 2048 tokens.
    parser.add_argument("--max-seq-length", type=int, default=2048)
    # Unsloth's Gemma 4 guide uses r=8/alpha=8 and notes "larger r = higher
    # accuracy, but might overfit" and "alpha == r at least". With ~1.4k highly
    # formatted examples r=16/alpha=16 is a safe middle; drop to 8 if the val
    # loss curves show overfit.
    parser.add_argument("--r", type=int, default=16)
    parser.add_argument("--alpha", type=int, default=16)
    parser.add_argument("--epochs", type=float, default=2.0)
    # Docs default 2e-4 ("reduce to 2e-5 for long training runs") — 2-3 epochs
    # over ~1.4k rows is short, so 2e-4 cosine is right.
    parser.add_argument("--lr", type=float, default=2e-4)
    parser.add_argument("--batch-size", type=int, default=8,
                        help="per-device batch (8 fits A100/4090 at seq 2048; "
                             "lower to 2-4 with --load-in-4bit on small cards)")
    parser.add_argument("--grad-accum", type=int, default=2)
    parser.add_argument("--load-in-4bit", action="store_true",
                        help="QLoRA (use for E4B on <=24 GB cards)")
    parser.add_argument("--save-merged", action="store_true",
                        help="Also save merged fp16 weights to <out>/merged "
                             "(large; adapter alone is enough for export_gguf.sh)")
    parser.add_argument("--no-mask", action="store_true",
                        help="Train on full text instead of masking the prompt "
                             "(fallback if marker matching ever breaks)")
    parser.add_argument("--seed", type=int, default=3407)
    args = parser.parse_args()
    return args


def main():
    args = parse_args()
    os.makedirs(args.out, exist_ok=True)

    model, tokenizer = FastModel.from_pretrained(
        model_name=args.base,
        max_seq_length=args.max_seq_length,
        dtype=None,                    # auto (bf16 on Ampere+)
        load_in_4bit=args.load_in_4bit,
        full_finetuning=False,
    )

    # Sanity: the app's turn markers must be real tokens in this tokenizer,
    # otherwise the deployed prompt format and the training format diverge.
    for marker in ("<start_of_turn>", "<end_of_turn>"):
        # FastModel returns a multimodal Processor for gemma-4; positional text
        # lands in its `images` arg. Use the inner tokenizer directly.
        ids = getattr(tokenizer, "tokenizer", tokenizer)(marker, add_special_tokens=False)["input_ids"]
        if len(ids) != 1:
            raise SystemExit(
                "FATAL: %r tokenizes to %d tokens (%r) in %s — the app's raw "
                "Gemma template does not match this tokenizer. Do not train."
                % (marker, len(ids), ids, args.base))

    # Text-only LoRA on attention + MLP of the language tower. Vision stays
    # frozen; audio modules are never selected because we only opt into
    # language layers. r/alpha per docs guidance (see parse_args comments).
    model = FastModel.get_peft_model(
        model,
        finetune_vision_layers=False,
        finetune_language_layers=True,
        finetune_attention_modules=True,
        finetune_mlp_modules=True,
        r=args.r,
        lora_alpha=args.alpha,
        lora_dropout=0,
        bias="none",
        random_state=args.seed,
    )
    model.print_trainable_parameters()

    dataset = load_dataset(
        "json", data_files={"train": args.data, "val": args.val})

    bf16 = torch.cuda.is_bf16_supported()
    config = SFTConfig(
        output_dir=os.path.join(args.out, "checkpoints"),
        dataset_text_field="text",
        max_length=args.max_seq_length,
        per_device_train_batch_size=args.batch_size,
        per_device_eval_batch_size=args.batch_size,
        gradient_accumulation_steps=args.grad_accum,
        num_train_epochs=args.epochs,
        learning_rate=args.lr,
        lr_scheduler_type="cosine",
        warmup_ratio=0.03,
        optim="adamw_8bit",
        weight_decay=0.001,
        logging_steps=5,
        eval_strategy="epoch",
        save_strategy="epoch",
        seed=args.seed,
        bf16=bf16,
        fp16=not bf16,
        # No packing: examples are short, and packing would interleave
        # documents under the prompt-masking pass below (the Unsloth Gemma 4
        # guide's SFT example also trains unpacked).
        packing=False,
        report_to="none",
    )

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=dataset["train"],
        eval_dataset=dataset["val"],
        args=config,
    )

    if not args.no_mask:
        # Mask everything before (and including) the model-turn marker so the
        # loss covers only the completion + <end_of_turn>. Markers are the
        # app's raw Gemma markers (NOT the gemma-4 chat-template ones — we
        # never applied get_chat_template; see module docstring).
        trainer = train_on_responses_only(
            trainer,
            instruction_part=INSTRUCTION_PART,
            response_part=RESPONSE_PART,
        )
        # Show what the loss actually sees for row 0 — should be the
        # completion plus <end_of_turn>, nothing from the prompt.
        sample = trainer.train_dataset[0]
        supervised = [t for t, l in zip(sample["input_ids"], sample["labels"]) if l != -100]
        print("--- supervised tokens of first row ---")
        print(tokenizer.decode(supervised))
        print("---------------------------------------")

    stats = trainer.train()
    print("train metrics:", stats.metrics)

    eval_metrics = trainer.evaluate()
    print("final eval metrics:", eval_metrics)
    with open(os.path.join(args.out, "metrics.json"), "w", encoding="utf-8") as handle:
        json.dump({"train": stats.metrics, "eval": eval_metrics,
                   "args": vars(args)}, handle, indent=2)

    # LoRA adapter — the artifact export_gguf.sh consumes.
    adapter_dir = os.path.join(args.out, "adapter")
    model.save_pretrained(adapter_dir)
    tokenizer.save_pretrained(adapter_dir)
    print("saved LoRA adapter ->", adapter_dir)

    if args.save_merged:
        # Merged fp16 safetensors (debug/inspection only). Do NOT use
        # save_pretrained_gguf on this model — unsloth bug #6808: the GGUF
        # converter fails mapping audio_tower tensors of the merged
        # multimodal checkpoint. Use export_gguf.sh instead.
        merged_dir = os.path.join(args.out, "merged")
        model.save_pretrained_merged(merged_dir, tokenizer, save_method="merged_16bit")
        print("saved merged fp16 model ->", merged_dir)


if __name__ == "__main__":
    main()
