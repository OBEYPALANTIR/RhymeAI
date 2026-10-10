#!/usr/bin/env python3
"""Synthetic training-data generator for the RhymeAI Gemma fine-tune.

Loop: sample a random case (data/sample_cases.py, eval-schema compatible)
-> build the app's EXACT inner prompt (eval.run_eval.prepare_case / eval.prompts)
-> query a teacher model over HTTP (data/teacher.py; --api completion wraps
   it in the app's on-device envelope, --envelope gemma4 by default or legacy
   for a Gemma 1-3n teacher GGUF; --api chat leaves templating to the server)
-> clean control-marker artifacts from the teacher text
-> score the CLEANED text with the eval scorers (eval.run_eval.score_case)
-> keep only completions that fully pass -> append a JSONL record.

The stored completion is the clean text WITHOUT any Gemma/turn markers, and
the stored prompt is the INNER user prompt (templates are applied at training
time).

Usage:
  python3 finetune/data/generate.py \
      --endpoint http://127.0.0.1:8080 --api completion \
      --count 500 --seed 1 --out finetune/data/out/train-v1.jsonl

Resume: re-run with the same --seed/--out; already-emitted sample indexes are
skipped (append mode) and previously written completions stay in the dedup set.

Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
import time
import zlib

_FINETUNE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _FINETUNE_DIR not in sys.path:
    sys.path.insert(0, _FINETUNE_DIR)

from eval import prompts, scoring  # noqa: E402
from eval.run_eval import envelope_mismatch, prepare_case, score_case  # noqa: E402
from data import sample_cases, teacher  # noqa: E402

MAX_ATTEMPTS_PER_SAMPLE = 3  # first draw + up to 2 re-draws
TASKS = ("suggestions", "rewrite_passage", "rewrite_word", "synonyms")
MIN_SYNONYMS = 3  # reject degenerate 1-2 word synonym lists

# ---------------------------------------------------------------------------
# Teacher-output cleaning (BEFORE scoring).
#
# Mirrors the app's stripping pipeline in AIService.kt: modelPayloadPrefixPattern
# (handled by scoring.strip_model_output), plus markerPrefixPattern /
# markerOnlyPattern for leading fragments like "_response>", ">", "model:".
# Cleaning before scoring is correct here because the TRAINING completion must
# be the clean text — the scorers then verify exactly what we store.
# ---------------------------------------------------------------------------

MARKER_PREFIX_RE = re.compile(
    r"^\s*(?:_?response>|_?output>|_?model_response>|assistant_response>|"
    r"model_response>|assistant:|model:|user:|"
    # Bare underscore-led marker with no ">" (e.g. "_response", "_output") —
    # the v1/v2 E2B stray-prefix regression traced back to these surviving.
    r"_(?:response|output|model_response)\b|"
    r"<?/?(?:start_of_turn|end_of_turn)>?\w*)\s*",
    re.IGNORECASE,
)
# "<[^>|]+>" leaves Gemma 4's pipe-delimited control tokens (<turn|>,
# <|channel>, ...) in place even on a line of their own, so the scorer
# rejects the sample instead of the cleaner hiding a derailment. An echoed
# <|turn>model opener is already cut by scoring.strip_model_output.
MARKER_ONLY_RE = re.compile(
    r"^\s*(?:_?response>|_?output>|_?model_response>|assistant_response>|"
    r"model_response>|_(?:response|output|model_response)\b|"
    r"<?/?(?:start_of_turn|end_of_turn)>?\w*|<[^>|]+>|>+|"
    r"[<>/]+|user|model|assistant)\s*$",
    re.IGNORECASE,
)

# Gemma 4 thinking channel. The 12B/26B/31B teachers open their answer with a
# "<|channel>thought\n...<channel|>" block (empty when thinking is off; E2B/E4B
# don't emit one), so that leading block is cut. Any other channel tag stays
# for the scorer to reject: the v3 seed3 pollution was EXTRA bare "<channel|>"
# closers inside the answer (75 lines shipped with them), and a sample carrying
# those is a derailment, not text to clean.
LEADING_THOUGHT_CHANNEL_RE = re.compile(r"\A\s*<\|channel>.*?<channel\|>\s*", re.DOTALL)


def clean_teacher_output(raw: str) -> str:
    text = scoring.strip_model_output(LEADING_THOUGHT_CHANNEL_RE.sub("", raw, count=1))
    cleaned_lines = []
    for line in text.split("\n"):
        if MARKER_ONLY_RE.match(line):
            continue
        while True:
            match = MARKER_PREFIX_RE.match(line)
            if match and match.end() > 0:
                line = line[match.end():]
            else:
                break
        # Leading ">" fragments glued to the payload (e.g. ">gleaming").
        line = re.sub(r"^\s*>+\s*", "", line)
        cleaned_lines.append(line)
    while cleaned_lines and not cleaned_lines[0].strip():
        cleaned_lines.pop(0)
    while cleaned_lines and not cleaned_lines[-1].strip():
        cleaned_lines.pop()
    return "\n".join(cleaned_lines).strip()


# ---------------------------------------------------------------------------
# Salvage for list-shaped tasks: keep only fully valid lines, then the final
# text is re-scored with the eval scorers, so the verification guarantee holds.
# ---------------------------------------------------------------------------

def salvage_suggestions(text: str, case: dict, constraint) -> str | None:
    lines = [l.strip() for l in text.split("\n") if l.strip()]
    existing = {
        scoring.normalize_suggestion_key(l)
        for l in case["lyrics"].split("\n")
        if scoring.normalize_suggestion_key(l)
    }
    matches = scoring.find_rhymes(constraint.target_word) if constraint else None
    picked, seen = [], set()
    for line in lines:
        if scoring._line_violations(line):
            continue
        key = scoring.normalize_suggestion_key(line)
        if not key or key in existing or key in seen:
            continue
        if constraint is not None:
            end = scoring.line_end_word(line)
            in_candidates = bool(end) and end in constraint.candidate_words
            if not in_candidates and scoring.rhyme_tier(line, matches) == 0:
                continue  # miss
        seen.add(key)
        picked.append(line)
        if len(picked) == prompts.SUGGESTION_COUNT:
            break
    if len(picked) < prompts.SUGGESTION_COUNT:
        return None
    return "\n".join(picked)


def salvage_synonyms(text: str, case: dict) -> str | None:
    target_key = scoring.normalize_suggestion_key(case["word"])
    picked, seen = [], set()
    for line in text.split("\n"):
        word = line.strip()
        if not word or scoring.LIST_PREFIX_RE.search(word):
            continue
        if not scoring.is_single_word(word):
            continue
        key = scoring.normalize_suggestion_key(word)
        if not key or key == target_key or key in seen:
            continue
        if scoring.PROMPT_ECHO_RE.search(word):
            continue
        seen.add(key)
        picked.append(word)
        if len(picked) == case["limit"]:
            break
    if len(picked) < MIN_SYNONYMS:
        return None
    return "\n".join(picked)


# ---------------------------------------------------------------------------
# Acceptance: format pass + rhyme compliance per task.
# ---------------------------------------------------------------------------

def accepted(task: str, score: dict) -> bool:
    if not score["format"]["passed"]:
        return False
    if task == "suggestions":
        rhyme = score.get("rhyme")
        if rhyme is not None and rhyme["miss"] > 0:
            return False
    elif task == "rewrite_word":
        rhyme = score.get("rhyme")  # present only for HARDER_RHYME
        if rhyme is not None and not rhyme["is_perfect_rhyme"]:
            return False
    elif task == "synonyms":
        if score["format"]["word_count"] < MIN_SYNONYMS:
            return False
    return True


def dedup_key(task: str, completion: str, case_params: dict | None = None) -> str:
    # Single-word rewrites legitimately repeat answers across different source
    # words and songs ("crooked"→"askew" in five songs is five valid examples),
    # so scope their dedup to the specific word+action+song instead of globally.
    if task == "rewrite_word" and case_params:
        scope = "|".join([
            str(case_params.get("song_id", "")),
            str(case_params.get("selection", "")),
            str(case_params.get("action", "")),
        ])
        return task + "|" + scope + "|" + scoring.normalize_suggestion_key(completion)
    return task + "|" + scoring.normalize_suggestion_key(completion)


# ---------------------------------------------------------------------------
# Resume support
# ---------------------------------------------------------------------------

def load_existing(out_path: str, run_seed: int):
    done_indexes, dedup = set(), set()
    if not os.path.exists(out_path):
        return done_indexes, dedup
    with open(out_path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            dedup.add(dedup_key(record.get("task", ""), record.get("completion", ""), record.get("case_params")))
            if record.get("run_seed") == run_seed and "sample_index" in record:
                done_indexes.add(record["sample_index"])
    return done_indexes, dedup


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def generate_one(client, case, case_seed):
    """(record_or_None, reason) for a single sampled case."""
    case = dict(case)
    case["id"] = case_seed
    prepared = prepare_case(case)
    # zlib.crc32 is stable across processes (unlike hash() on strings).
    raw = client.generate(prepared["user_prompt"], seed=zlib.crc32(case_seed.encode("utf-8")))
    completion = clean_teacher_output(raw)
    if not completion:
        return None, "empty_output"

    score = score_case(prepared, completion)
    if not accepted(case["task"], score):
        salvaged = None
        if case["task"] == "suggestions":
            salvaged = salvage_suggestions(
                completion, case, prepared.get("constraint")
            )
        elif case["task"] == "synonyms":
            salvaged = salvage_synonyms(completion, case)
        if salvaged is None:
            return None, "rejected_by_scorer"
        score = score_case(prepared, salvaged)
        if not accepted(case["task"], score):
            return None, "rejected_by_scorer"
        completion = salvaged

    record = {
        "task": case["task"],
        "case_seed": case_seed,
        "case_params": {k: v for k, v in case.items() if k != "id"},
        "user_prompt": prepared["user_prompt"],
        "completion": completion,
    }
    return record, "accepted"


def main():
    parser = argparse.ArgumentParser(
        description="Generate verified (prompt -> completion) training pairs "
                    "by querying a teacher model and keeping only outputs "
                    "that pass the eval scorers.",
    )
    parser.add_argument("--endpoint", required=True,
                        help="Teacher base URL, e.g. http://127.0.0.1:8080")
    parser.add_argument("--api", choices=["completion", "chat"], default="completion",
                        help="completion = llama-server /completion with the app's "
                             "raw envelope; chat = OpenAI-compatible "
                             "/v1/chat/completions with the inner user prompt")
    parser.add_argument("--envelope", choices=sorted(prompts.ENVELOPE_OPTIONS),
                        default="gemma4",
                        help="Turn envelope for --api completion: the teacher GGUF's "
                             "family (default gemma4; legacy for Gemma 1-3n). "
                             "Ignored for --api chat")
    parser.add_argument("--count", type=int, default=500,
                        help="Number of samples to attempt (default 500)")
    parser.add_argument("--seed", type=int, default=1, help="Run seed (default 1)")
    parser.add_argument("--out", default="finetune/data/out/train-v1.jsonl",
                        help="Output JSONL path (append mode; enables resume)")
    parser.add_argument("--temperature", type=float, default=teacher.DEFAULT_TEMPERATURE)
    parser.add_argument("--retries", type=int, default=teacher.DEFAULT_RETRIES,
                        help="HTTP retries per request (default 2)")
    parser.add_argument("--timeout", type=float, default=teacher.DEFAULT_TIMEOUT_S,
                        help="HTTP timeout seconds (default 300)")
    parser.add_argument("--model", default="",
                        help="Model name for chat API payloads (optional)")
    parser.add_argument("--api-key", default="",
                        help="Bearer token for chat API endpoints (optional)")
    parser.add_argument("--tasks", default="",
                        help="Comma-separated task filter (e.g. rewrite_word) "
                             "for targeted top-up runs; empty = all tasks")
    args = parser.parse_args()
    allowed_tasks = {t.strip() for t in args.tasks.split(",") if t.strip()}
    if allowed_tasks - set(TASKS):
        sys.exit("unknown tasks: %s" % ", ".join(sorted(allowed_tasks - set(TASKS))))

    envelope = prompts.ENVELOPE_OPTIONS[args.envelope]
    if args.api == "completion":
        mismatch = envelope_mismatch(args.endpoint, envelope)
        if mismatch:
            print("WARNING: %s" % mismatch)
    client = teacher.TeacherClient(
        endpoint=args.endpoint,
        api=args.api,
        envelope=envelope,
        temperature=args.temperature,
        retries=args.retries,
        timeout_s=args.timeout,
        model=args.model,
        api_key=args.api_key,
    )

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    done_indexes, dedup = load_existing(args.out, args.seed)
    if done_indexes:
        print("resume: %d sample indexes already emitted for seed %d; %d "
              "completions in dedup set" % (len(done_indexes), args.seed, len(dedup)))

    stats = {t: {"queries": 0, "accepted": 0, "rejected": 0,
                 "duplicates": 0, "empty": 0} for t in TASKS}
    unbuildable_draws = 0
    unfilled = 0
    started = time.time()

    with open(args.out, "a", encoding="utf-8") as out_handle:
        for index in range(args.count):
            if index in done_indexes:
                continue
            emitted = False
            for attempt in range(MAX_ATTEMPTS_PER_SAMPLE):
                case_seed = "%d-%d-%d" % (args.seed, index, attempt)
                rng = random.Random(case_seed)
                case = sample_cases.sample_case(rng)
                # Task filter: redraw from the same per-attempt rng stream so
                # filtered runs stay deterministic for a given seed.
                redraws = 0
                while case is not None and allowed_tasks and case["task"] not in allowed_tasks:
                    redraws += 1
                    if redraws > 200:
                        case = None
                        break
                    case = sample_cases.sample_case(rng)
                if case is None:
                    unbuildable_draws += 1
                    continue
                task = case["task"]
                stats[task]["queries"] += 1
                try:
                    record, reason = generate_one(client, case, case_seed)
                except teacher.TeacherError as error:
                    sys.exit("aborting (progress is saved in %s): %s"
                             % (args.out, error))
                if record is None:
                    stats[task]["rejected" if reason == "rejected_by_scorer"
                               else "empty"] += 1
                    print("[%4d/%d] %-16s attempt %d %s" % (
                        index + 1, args.count, task, attempt, reason))
                    continue
                key = dedup_key(task, record["completion"], record.get("case_params"))
                if key in dedup:
                    stats[task]["duplicates"] += 1
                    print("[%4d/%d] %-16s attempt %d duplicate_completion" % (
                        index + 1, args.count, task, attempt))
                    continue
                dedup.add(key)
                record["run_seed"] = args.seed
                record["sample_index"] = index
                out_handle.write(json.dumps(record, ensure_ascii=False) + "\n")
                out_handle.flush()
                stats[task]["accepted"] += 1
                print("[%4d/%d] %-16s attempt %d ACCEPTED" % (
                    index + 1, args.count, task, attempt))
                emitted = True
                break
            if not emitted:
                unfilled += 1

    elapsed = time.time() - started
    print()
    print("=" * 72)
    print("GENERATION SUMMARY  (%.1fs, out: %s)" % (elapsed, args.out))
    print("=" * 72)
    header = "%-16s %8s %9s %9s %6s %6s %8s" % (
        "task", "queries", "accepted", "rejected", "dup", "empty", "accept%")
    print(header)
    print("-" * len(header))
    total_accepted = 0
    for task in TASKS:
        s = stats[task]
        total_accepted += s["accepted"]
        rate = 100.0 * s["accepted"] / s["queries"] if s["queries"] else 0.0
        print("%-16s %8d %9d %9d %6d %6d %7.0f%%" % (
            task, s["queries"], s["accepted"], s["rejected"],
            s["duplicates"], s["empty"], rate))
    print("-" * len(header))
    print("records emitted this run: %d   unfilled samples: %d   "
          "unbuildable draws: %d" % (total_accepted, unfilled, unbuildable_draws))


if __name__ == "__main__":
    main()
