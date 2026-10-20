#!/usr/bin/env python3
"""Bounded Gemma 4 12B QLoRA pilot; saves evidence, never promotes a teacher."""

import argparse
import collections
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import re
import time
import traceback

BASE = "google/gemma-4-12B-it"
REVISION = "707f0a3b8a3c7ad586ed01e27eafbad8a27dd0f7"
MAX_LENGTH = 2048


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_splits(root):
    root = Path(root)
    manifest = json.loads((root / "manifest.json").read_text())
    splits = {}
    for name, expected in manifest["splits"].items():
        path = root / (name + ".jsonl")
        if sha(path) != expected["sha256"]:
            raise ValueError("Dataset changed: " + name)
        splits[name] = [json.loads(line) for line in path.read_text().splitlines()]
        if len(splits[name]) != expected["rows"]:
            raise ValueError("Dataset row count changed")
    for left, right in (("train", "validation"), ("train", "test"), ("validation", "test")):
        for key in ("group", "prompt_sha256"):
            if {r[key] for r in splits[left]} & {r[key] for r in splits[right]}:
                raise ValueError("Dataset leakage")
    return splits, manifest


def balanced_subset(rows, per_task):
    selected = []
    for task in sorted({r["task"] for r in rows}):
        values = sorted((r for r in rows if r["task"] == task), key=lambda r: r["prompt_sha256"])
        seen = set()
        for row in values:
            if row["prompt_sha256"] not in seen:
                selected.append(row)
                seen.add(row["prompt_sha256"])
            if len(seen) == per_task:
                break
        if len(seen) != per_task:
            raise ValueError("Not enough distinct prompts for " + task)
    return selected


# The app's on-device envelope, byte for byte: GGUFModelService.gemmaPrompt
# (gemma4 case) on iOS, mirrored by finetune/eval/prompts.GEMMA4. It has no
# system turn and no thought channel, and the app never trims the prompt. The
# app's llama.cpp adds one <bos>; every tokenizer call here passes
# add_special_tokens=False, so the <bos> is written into the text instead.
# Inlined because make_teacher_colab.py packages only this file.
APP_USER = "<|turn>user\n"
APP_MODEL = "<turn|>\n<|turn>model\n"
APP_END = "<turn|>"


def prompt_text(tokenizer, prompt):
    return tokenizer.bos_token + APP_USER + prompt + APP_MODEL


def supervised_row(tokenizer, row):
    prefix = prompt_text(tokenizer, row["prompt"])
    # The app stops generating at <turn|>, so nothing after it is supervised.
    answer = row["completion"] + APP_END
    prefix_ids = tokenizer.encode(prefix, add_special_tokens=False)
    if prefix_ids[:1] != [tokenizer.bos_token_id] or prefix_ids.count(tokenizer.bos_token_id) != 1 \
            or tokenizer.convert_tokens_to_ids("<|channel>") in prefix_ids:
        raise ValueError("Prompt prefix is not <bos> + the app envelope")
    encoded = tokenizer(prefix + answer, add_special_tokens=False, truncation=False)
    ids = encoded["input_ids"]
    if ids[:len(prefix_ids)] != prefix_ids:
        raise ValueError("Prompt/completion token boundary changed")
    if len(ids) > MAX_LENGTH:
        raise ValueError("Training example exceeds context; refuse silent truncation")
    suffix_ids = ids[len(prefix_ids):]
    if not suffix_ids or tokenizer.decode(suffix_ids, skip_special_tokens=False).strip() != answer.strip():
        raise ValueError("Completion supervision does not cover the complete answer")
    return {"input_ids": ids, "attention_mask": [1] * len(ids),
            "labels": [-100] * len(prefix_ids) + suffix_ids}


def structural_score(text, task, prompt):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    unique = len(set(line.casefold() for line in lines)) == len(lines)
    controls = bool(re.search(r"<\||\|>|(?:^|\n)_?(?:response|output)\s*>?", text, re.I))
    if task == "suggestions":
        return len(lines) == 6 and unique and not controls
    if task == "rewrite_word":
        return len(lines) == 1 and bool(re.fullmatch(r"[A-Za-z]+(?:['’-][A-Za-z]+)*", lines[0])) and not controls
    if task == "synonyms":
        target = re.search(r"<target>(.*?)</target>", prompt, re.S)
        return (3 <= len(lines) <= 8 and unique and not controls
                and all(re.fullmatch(r"[A-Za-z]+(?:['’-][A-Za-z]+)*", line) for line in lines)
                and (not target or target.group(1).casefold() not in {line.casefold() for line in lines}))
    return bool(lines) and not controls


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--deadline", type=float, required=True)
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=False)
    started = time.time()
    os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    status = {"status": "preflight", "model": BASE, "revision": REVISION,
              "started_epoch": started, "deadline_epoch": args.deadline,
              "teacher_accepted": False}
    write_json(out / "status.json", status)
    try:
        import torch
        from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
        from transformers import (AutoTokenizer, BitsAndBytesConfig,
                                  Gemma4UnifiedForConditionalGeneration,
                                  Trainer, TrainerCallback, TrainingArguments, set_seed)
        from huggingface_hub import hf_hub_download

        if not torch.cuda.is_available() or not torch.cuda.is_bf16_supported():
            raise RuntimeError("A CUDA GPU with BF16 support is required")
        total_memory = torch.cuda.get_device_properties(0).total_memory
        if total_memory < 22_000_000_000:
            raise RuntimeError("This pilot requires at least 22 GB GPU memory")
        batch_size = 2 if total_memory >= 35_000_000_000 else 1
        training_args = TrainingArguments(output_dir=str(out / "checkpoints"),
            num_train_epochs=1, per_device_train_batch_size=batch_size,
            per_device_eval_batch_size=1, gradient_accumulation_steps=16 // batch_size,
            learning_rate=2e-5, lr_scheduler_type="cosine", warmup_steps=0.03,
            optim="paged_adamw_8bit", bf16=True, gradient_checkpointing=True,
            gradient_checkpointing_kwargs={"use_reentrant": False},
            eval_strategy="no", save_strategy="steps", save_steps=100,
            logging_steps=10, logging_nan_inf_filter=False, report_to="none",
            remove_unused_columns=False, dataloader_num_workers=0, seed=3407,
            data_seed=3407, push_to_hub=False, disable_tqdm=True)
        set_seed(3407)
        raw, manifest = read_splits(args.data)
        tokenizer = AutoTokenizer.from_pretrained(BASE, revision=REVISION, token=False)
        if not tokenizer.chat_template:
            template = hf_hub_download(BASE, "chat_template.jinja", revision=REVISION, token=False)
            tokenizer.chat_template = Path(template).read_text()
        tokenizer.padding_side = "right"
        if tokenizer.convert_tokens_to_ids("<turn|>") not in (1, 50, 106):
            raise ValueError("Unexpected Gemma turn terminator")
        datasets, token_audit = {}, {}
        for split in ("train", "validation"):
            values = raw[split] if split == "train" else balanced_subset(raw[split], 24)
            datasets[split] = [supervised_row(tokenizer, row) for row in values]
            supervised = collections.Counter()
            for row, encoded in zip(values, datasets[split]):
                supervised[row["task"]] += sum(label != -100 for label in encoded["labels"])
            token_audit[split] = {"rows": len(values), "supervised_tokens_by_task": dict(supervised),
                                  "max_tokens": max(len(r["input_ids"]) for r in datasets[split]),
                                  "prompt_masked": True, "truncated_rows": 0}
        test_rows = balanced_subset(raw["test"], 6)
        write_json(out / "dataset-manifest.json", manifest)
        write_json(out / "token-audit.json", token_audit)
        versions = {name: importlib.metadata.version(name) for name in
                    ("torch", "transformers", "peft", "accelerate", "bitsandbytes", "huggingface-hub")}
        write_json(out / "environment.json", {"versions": versions,
                   "gpu": torch.cuda.get_device_name(0), "gpu_memory_bytes": total_memory,
                   "cuda": torch.version.cuda, "script_sha256": sha(__file__)})
        print("TOKEN_AUDIT", json.dumps(token_audit), flush=True)
        quantization = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                                         bnb_4bit_use_double_quant=True,
                                         bnb_4bit_compute_dtype=torch.bfloat16)
        model = Gemma4UnifiedForConditionalGeneration.from_pretrained(
            BASE, revision=REVISION, token=False, torch_dtype=torch.bfloat16,
            quantization_config=quantization, device_map={"": 0}, attn_implementation="sdpa")
        model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True,
                                                gradient_checkpointing_kwargs={"use_reentrant": False})
        model = get_peft_model(model, LoraConfig(r=16, lora_alpha=16, lora_dropout=0.05,
                              bias="none", task_type="CAUSAL_LM",
                              target_modules=r".*language_model.*\.(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)"))

        def adapter_hash():
            h = hashlib.sha256()
            for name, parameter in model.named_parameters():
                if parameter.requires_grad:
                    h.update(name.encode())
                    h.update(parameter.detach().float().cpu().contiguous().numpy().tobytes())
            return h.hexdigest()

        initial_adapter_hash = adapter_hash()

        def generate_arm(arm):
            model.eval()
            records = []
            path = out / (arm + "-responses.jsonl")
            with path.open("x") as handle:
                for row in test_rows:
                    for seed in (17, 41):
                        if time.time() > args.deadline - 120:
                            raise TimeoutError("Evaluation reached run deadline")
                        set_seed(seed)
                        inputs = tokenizer(prompt_text(tokenizer, row["prompt"]),
                                           return_tensors="pt", add_special_tokens=False).to("cuda")
                        before = time.monotonic()
                        with torch.inference_mode():
                            output = model.generate(**inputs, max_new_tokens=384,
                                do_sample=True, temperature=0.7, top_k=40, top_p=0.95,
                                repetition_penalty=1.0, use_cache=True,
                                eos_token_id=[1, 50, 106], pad_token_id=tokenizer.pad_token_id)
                        generated = output[0, inputs["input_ids"].shape[1]:]
                        text = tokenizer.decode(generated, skip_special_tokens=True).strip()
                        record = {"arm": arm, "prompt_sha256": row["prompt_sha256"],
                                  "task": row["task"], "seed": seed, "prompt": row["prompt"],
                                  "response": text, "tokens": len(generated),
                                  "elapsed_s": time.monotonic() - before,
                                  "format_pass": structural_score(text, row["task"], row["prompt"]),
                                  "hit_token_limit": len(generated) == 384 and generated[-1].item() not in (1, 50, 106)}
                        handle.write(json.dumps(record, ensure_ascii=False) + "\n")
                        handle.flush()
                        records.append(record)
            return {task: {"passed": sum(r["format_pass"] and not r["hit_token_limit"] for r in records if r["task"] == task),
                           "total": sum(r["task"] == task for r in records)} for task in sorted({r["task"] for r in records})}

        def collate(rows):
            length = max(len(row["input_ids"]) for row in rows)
            batch = {}
            for key, padding in (("input_ids", tokenizer.pad_token_id), ("attention_mask", 0), ("labels", -100)):
                batch[key] = torch.tensor([row[key] + [padding] * (length - len(row[key])) for row in rows])
            if torch.any(batch["labels"][batch["attention_mask"] == 0] != -100):
                raise ValueError("Padding contributes to loss")
            return batch

        status["status"] = "baseline_evaluation"
        write_json(out / "status.json", status)
        with model.disable_adapter():
            baseline = generate_arm("stock")
        write_json(out / "baseline-summary.json", baseline)
        model.config.use_cache = False
        model.config.text_config.use_cache = False
        train_started = time.time()
        stop_reason = None

        class Monitor(TrainerCallback):
            def on_step_end(self, training_args, state, control, **kwargs):
                nonlocal stop_reason
                elapsed = time.time() - train_started
                if state.global_step == 10:
                    current = adapter_hash()
                    if current == initial_adapter_hash:
                        raise RuntimeError("Optimizer steps did not change trainable weights")
                    write_json(out / "weight-update-proof.json", {"global_step": state.global_step,
                               "initial_sha256": initial_adapter_hash, "updated_sha256": current})
                    control.should_save = True
                if state.global_step >= 10 and state.global_step % 10 == 0:
                    remaining = elapsed / state.global_step * (state.max_steps - state.global_step)
                    status.update(status="training", global_step=state.global_step,
                                  max_steps=state.max_steps, train_elapsed_s=elapsed,
                                  projected_remaining_s=remaining,
                                  peak_gpu_bytes=torch.cuda.max_memory_allocated())
                    write_json(out / "status.json", status)
                    print("PROGRESS", json.dumps(status), flush=True)
                    if time.time() + remaining + 1800 > args.deadline:
                        stop_reason = "projected_over_budget"
                if time.time() > args.deadline - 1800:
                    stop_reason = "deadline_reserve"
                if stop_reason:
                    control.should_training_stop = True
                    control.should_save = True
                return control

            def on_log(self, training_args, state, control, logs=None, **kwargs):
                if any(isinstance(value, (int, float)) and not math.isfinite(value) for value in (logs or {}).values()):
                    raise RuntimeError("Non-finite training metric")

        trainer = Trainer(model=model, args=training_args, data_collator=collate,
                          train_dataset=datasets["train"], eval_dataset=datasets["validation"],
                          callbacks=[Monitor()])
        probe = collate(datasets["train"][:batch_size])
        model.eval()
        with torch.no_grad():
            loss = model(**{k: v.to("cuda") for k, v in probe.items()}).loss
        if not torch.isfinite(loss):
            raise RuntimeError("Non-finite CUDA preflight loss")
        write_json(out / "gpu-preflight.json", {"finite_loss": float(loss),
                   "trainable_parameters": sum(p.numel() for p in model.parameters() if p.requires_grad),
                   "total_parameters": sum(p.numel() for p in model.parameters()), "batch_size": batch_size})
        del probe, loss
        torch.cuda.empty_cache()
        stats = trainer.train()
        model.save_pretrained(out / "adapter", safe_serialization=True)
        tokenizer.save_pretrained(out / "adapter")
        trainer.save_state()
        trained_hash = adapter_hash()
        if trained_hash == initial_adapter_hash:
            raise RuntimeError("Saved model is unchanged")
        eval_metrics = trainer.evaluate()
        write_json(out / "metrics.json", {"train": stats.metrics, "validation": eval_metrics,
                   "global_step": trainer.state.global_step, "stop_reason": stop_reason,
                   "initial_adapter_sha256": initial_adapter_hash, "final_trainable_sha256": trained_hash})
        if stop_reason:
            status.update(status="partial_checkpoint_saved", stop_reason=stop_reason)
        else:
            # Reload the saved adapter into the same pinned base before inference.
            model.load_adapter(str(out / "adapter"), adapter_name="saved_reload", is_trainable=False)
            model.set_adapter("saved_reload")
            candidate = generate_arm("candidate")
            write_json(out / "comparison.json", {"stock": baseline, "candidate": candidate,
                       "paired_prompts": len(test_rows), "seeds": [17, 41],
                       "teacher_accepted": False,
                       "pending": "Blind lyric-quality review; format scores alone cannot accept a teacher."})
            status.update(status="trained_and_reloaded", global_step=trainer.state.global_step,
                          validation_loss=eval_metrics["eval_loss"])
        hashes = {str(path.relative_to(out)): sha(path) for path in (out / "adapter").iterdir() if path.is_file()}
        write_json(out / "adapter-hashes.json", hashes)
        status["elapsed_s"] = time.time() - started
        write_json(out / "status.json", status)
        print("FINAL_STATUS", json.dumps(status), flush=True)
    except Exception as error:
        status.update(status="failed", error=type(error).__name__ + ": " + str(error),
                      elapsed_s=time.time() - started)
        write_json(out / "status.json", status)
        (out / "error-traceback.txt").write_text(traceback.format_exc())
        raise


if __name__ == "__main__":
    main()
