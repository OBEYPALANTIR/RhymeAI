#!/usr/bin/env python3
"""Phase 3 step 1 — convert verified training records into SFT-ready JSONL.

Runs LOCALLY (stdlib only). Takes the Phase 2 output
(finetune/data/out/train-v1.jsonl, records of
{"task", "case_params", "user_prompt", "completion", ...}) and emits
train/val JSONL where each record carries a "text" field holding the FULL
training example in the app's on-device envelope. For the shipped Gemma 4
E2B/E4B models (--envelope gemma4, the default) that is

    <|turn>user
    {user_prompt}<turn|>
    <|turn>model
    {completion}<turn|>

The prompt half is `eval.prompts.app_prompt`, the byte-for-byte port of
GGUFModelService.gemmaPrompt, so the text the LoRA trains on starts with
EXACTLY the text the app tokenizes at inference time. It carries no <bos>:
llama.cpp adds one in the app, and train_lora.py makes sure training sees
exactly one (Gemma 4's HF tokenizer adds none itself). The model turn closes
with the family's end-of-turn token, which the app stops on.
--envelope gemmaLegacy keeps the <start_of_turn> form for Gemma 1-3n bases;
that prompt ends at "<start_of_turn>model", so the completion follows a
newline there.

Also:
  - shuffles deterministically (--seed),
  - splits train/val 97/3, stratified per task so eval-loss covers all four
    tasks even at small dataset sizes,
  - prints task-distribution and length stats,
  - warns on any example longer than --max-chars (default 6000 chars — a
    conservative proxy for the 2048-token training context; Gemma averages
    well under 3 chars/token on this prompt mix). Use --drop-over-max to
    exclude such records instead of just warning.

Usage:
  python3 finetune/train/prepare_dataset.py \
      --in finetune/data/out/train-v1.jsonl \
      --out-dir finetune/train/out

Dry run against the pilot set:
  python3 finetune/train/prepare_dataset.py \
      --in finetune/data/out/pilot-e4b.jsonl \
      --out-dir /tmp/prepare-dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
from collections import OrderedDict

_FINETUNE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _FINETUNE_DIR not in sys.path:
    sys.path.insert(0, _FINETUNE_DIR)

from eval.prompts import ENVELOPES, GEMMA4, app_prompt  # noqa: E402  (parity source of truth)

# Records hold the INNER prompt; the envelope is added here, once.
TURN_MARKERS = ("<start_of_turn>", "<end_of_turn>", "<|turn>", "<turn|>")


def build_text(user_prompt: str, completion: str, envelope=GEMMA4) -> str:
    """Full training example: the app's exact prompt, the completion, end of turn."""
    prompt = app_prompt(user_prompt, envelope)
    if not prompt.endswith("\n"):
        prompt += "\n"
    return prompt + completion + envelope.end_of_turn


def masking_markers(envelope=GEMMA4):
    """(instruction_part, response_part) train_lora.py masks the prompt with:
    everything through the model-turn line is prompt, the rest is supervised."""
    response_part = envelope.generation_prefix
    if not response_part.endswith("\n"):
        response_part += "\n"
    return envelope.user_marker, response_part


def load_records(path: str):
    records = []
    with open(path, "r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                sys.exit("%s:%d: bad JSON: %s" % (path, line_no, error))
            for key in ("task", "user_prompt", "completion"):
                if not record.get(key):
                    sys.exit("%s:%d: record missing %r" % (path, line_no, key))
            if any(marker in record["user_prompt"] for marker in TURN_MARKERS):
                sys.exit("%s:%d: user_prompt already carries turn markers; "
                         "records must hold the inner prompt" % (path, line_no))
            records.append(record)
    if not records:
        sys.exit("no records found in %s" % path)
    return records


def percentile(sorted_values, fraction):
    if not sorted_values:
        return 0
    index = min(len(sorted_values) - 1, int(round(fraction * (len(sorted_values) - 1))))
    return sorted_values[index]


def main():
    parser = argparse.ArgumentParser(
        description="Convert verified (prompt -> completion) records into "
                    "app-envelope SFT JSONL with a train/val split.")
    parser.add_argument("--envelope", choices=sorted(ENVELOPES), default=GEMMA4.name,
                        help="Prompt envelope of the base model family "
                             "(default gemma4: the shipped E2B/E4B models)")
    parser.add_argument("--in", dest="input", default="finetune/data/out/train-v1.jsonl",
                        help="Phase 2 JSONL (default finetune/data/out/train-v1.jsonl)")
    parser.add_argument("--out-dir", default="finetune/train/out",
                        help="Directory for train.jsonl / val.jsonl "
                             "(default finetune/train/out)")
    parser.add_argument("--seed", type=int, default=3407, help="Shuffle seed (default 3407)")
    parser.add_argument("--val-frac", type=float, default=0.03,
                        help="Validation fraction (default 0.03 = 97/3 split)")
    parser.add_argument("--max-chars", type=int, default=6000,
                        help="Warn when a full example exceeds this many chars "
                             "(default 6000; chars are a proxy for tokens)")
    parser.add_argument("--drop-over-max", action="store_true",
                        help="Drop over-length examples instead of only warning")
    args = parser.parse_args()

    records = load_records(args.input)
    envelope = ENVELOPES[args.envelope]

    # Build texts, dedup exact (task, text) repeats defensively (generate.py
    # already dedups completions per task, so this normally drops nothing).
    seen = set()
    examples = []
    over_limit = []
    duplicates = 0
    for record in records:
        text = build_text(record["user_prompt"], record["completion"], envelope)
        key = (record["task"], text)
        if key in seen:
            duplicates += 1
            continue
        seen.add(key)
        example = {
            "text": text,
            "task": record["task"],
            "case_seed": record.get("case_seed", ""),
        }
        if len(text) > args.max_chars:
            over_limit.append(example)
            if args.drop_over_max:
                continue
        examples.append(example)

    for example in over_limit:
        print("WARNING: example %s (%s) is %d chars (> %d)%s" % (
            example["case_seed"] or "<no seed>", example["task"],
            len(example["text"]), args.max_chars,
            " -- DROPPED" if args.drop_over_max else ""))
    if duplicates:
        print("note: skipped %d exact duplicate example(s)" % duplicates)

    # Deterministic shuffle + stratified 97/3 split. Stratifying per task keeps
    # the val split representative of the ~50/20/20/10 task mix, so eval loss
    # is comparable across runs. Tasks with < 4 records contribute no val rows.
    rng = random.Random(args.seed)
    by_task = OrderedDict()
    for example in examples:
        by_task.setdefault(example["task"], []).append(example)

    train_rows, val_rows = [], []
    for task in sorted(by_task):
        rows = by_task[task]
        rng.shuffle(rows)
        n_val = max(1, round(len(rows) * args.val_frac)) if len(rows) >= 4 else 0
        val_rows.extend(rows[:n_val])
        train_rows.extend(rows[n_val:])
    rng.shuffle(train_rows)
    rng.shuffle(val_rows)

    os.makedirs(args.out_dir, exist_ok=True)
    train_path = os.path.join(args.out_dir, "train.jsonl")
    val_path = os.path.join(args.out_dir, "val.jsonl")
    for path, rows in ((train_path, train_rows), (val_path, val_rows)):
        with open(path, "w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    # ----- stats -------------------------------------------------------
    lengths = sorted(len(e["text"]) for e in train_rows + val_rows)
    total = len(train_rows) + len(val_rows)
    print()
    print("=" * 68)
    print("PREPARED SFT DATASET  (envelope %s, seed %d, val_frac %.2f)" % (
        envelope.name, args.seed, args.val_frac))
    print("=" * 68)
    header = "%-16s %7s %7s %7s %8s" % ("task", "total", "train", "val", "share")
    print(header)
    print("-" * len(header))
    for task in sorted(by_task):
        n_train = sum(1 for e in train_rows if e["task"] == task)
        n_val = sum(1 for e in val_rows if e["task"] == task)
        n_task = n_train + n_val
        print("%-16s %7d %7d %7d %7.1f%%" % (
            task, n_task, n_train, n_val, 100.0 * n_task / total))
    print("-" * len(header))
    print("%-16s %7d %7d %7d" % ("all", total, len(train_rows), len(val_rows)))
    print()
    print("example length (chars): min %d  p50 %d  p95 %d  max %d" % (
        lengths[0], percentile(lengths, 0.50), percentile(lengths, 0.95), lengths[-1]))
    print("examples over %d chars: %d%s" % (
        args.max_chars, len(over_limit),
        " (dropped)" if args.drop_over_max and over_limit else ""))
    print()
    print("wrote %s (%d rows)" % (train_path, len(train_rows)))
    print("wrote %s (%d rows)" % (val_path, len(val_rows)))


if __name__ == "__main__":
    main()
