#!/usr/bin/env python3
"""Paired naturalness A/B eval — the quality gate the 43-case harness can't measure.

The format harness saturates (both tuned models pass ~100%), so base-model
decisions hinge on lyric CRAFT: natural phrasing, fresh imagery, no forced
rhymes. This tool runs both contestants on the SAME inner prompts (paired
design cancels prompt-level variance), blinds and shuffles the outputs, and
scores judgments with a two-sided sign test.

Three phases, joined by JSONL contracts so the judge is pluggable:

  generate  -> naturalness-pairs.jsonl     (blinded L/R pairs + answer key)
  judge     -> naturalness-judgments.jsonl (winner per pair; any judge works)
  report    -> verdict                     (wins/ties per task + sign test)

`judge` drives any OpenAI-compatible /v1/chat/completions endpoint (e.g. a
strong model on llama-server, or an API). Judgments produced by other means
are fine too — the report only needs {"pair_id", "winner": "L"|"R"|"tie"} rows.

Usage:
  run_naturalness.py generate --model-x <gguf> --template-x qwen \
      --model-y <gguf> --template-y gemma [--samples 2] [--out pairs.jsonl]
  run_naturalness.py judge --pairs pairs.jsonl --endpoint http://...:PORT \
      [--judge-model NAME] [--limit N] [--out judgments.jsonl]
  run_naturalness.py report --pairs pairs.jsonl --judgments judgments.jsonl
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import sys
import time
import urllib.request

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from eval import cases as cases_mod
    from eval import prompts, scoring
    from eval import run_eval
else:
    from . import cases as cases_mod
    from . import prompts, scoring
    from . import run_eval

# Naturalness lives in multi-line creative output; word rewrites and synonym
# lists are single-word tasks judged fully by the format harness.
TASKS = ("suggestions", "rewrite_passage")

JUDGE_PROMPT = """You are judging outputs from two on-device songwriting assistants.

Both assistants received exactly this task:
---
%s
---

Candidate L:
---
%s
---

Candidate R:
---
%s
---

Judge ONLY lyric craft and naturalness: natural phrasing and grammar, fresh vs
cliched imagery, forced or padded rhymes (e.g. lines ending "...slow, ago"),
word repetition across lines, and whether the lines read like human-written
lyrics. Ignore whitespace and minor formatting. Either, both, or neither may
be good; pick the better one or declare a tie.

Reply with ONLY a JSON object: {"winner": "L" | "R" | "tie", "reason": "<max 20 words>"}"""


def inner_prompt(templated: str) -> str:
    """Recover the template-independent inner user prompt from the gemma form."""
    prefix = "<start_of_turn>user\n"
    suffix = "\n<end_of_turn>\n<start_of_turn>model"
    assert templated.startswith(prefix) and templated.endswith(suffix), templated[:60]
    return templated[len(prefix):-len(suffix)]


def creative_cases():
    prompts.set_template("gemma")
    out = []
    for case in cases_mod.CASES:
        if case["task"] not in TASKS:
            continue
        prepared = run_eval.prepare_case(case)
        out.append({"id": prepared["id"], "task": prepared["task"],
                    "inner": inner_prompt(prepared["prompt"])})
    return out


def post_json(url: str, body: dict, timeout: int = 600) -> dict:
    request = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def generate_for_model(model_path: str, template: str, cases, samples: int, log_path: str):
    """Serve one contestant and sample `samples` completions per case."""
    prompts.set_template(template)
    tmpl = prompts.active_template()
    port = run_eval.free_port()
    print("serving %s (template %s) on port %d" % (os.path.basename(model_path), template, port))
    process, log_handle = run_eval.start_server(model_path, port, log_path)
    outputs = {}
    try:
        run_eval.wait_for_health(port, process)
        for index, case in enumerate(cases, 1):
            for k in range(samples):
                payload = post_json("http://127.0.0.1:%d/completion" % port, {
                    "prompt": prompts.instruction_prompt(case["inner"]),
                    "n_predict": run_eval.N_PREDICT,
                    "temperature": run_eval.TEMPERATURE,
                    "top_k": run_eval.TOP_K,
                    "top_p": run_eval.TOP_P,
                    "stop": list(tmpl.stop),
                    "seed": 7000 + k,
                    "cache_prompt": False,
                })
                outputs[(case["id"], k)] = scoring.strip_model_output(payload.get("content", ""))
            print("  [%2d/%2d] %s" % (index, len(cases), case["id"]))
    finally:
        run_eval.stop_server(process, log_handle)
    return outputs


def cmd_generate(args):
    cases = creative_cases()
    print("%d creative cases x %d samples per model" % (len(cases), args.samples))
    x_out = generate_for_model(args.model_x, args.template_x, cases, args.samples,
                               os.path.splitext(args.out)[0] + ".x.server.log")
    y_out = generate_for_model(args.model_y, args.template_y, cases, args.samples,
                               os.path.splitext(args.out)[0] + ".y.server.log")

    rng = random.Random(args.seed)
    x_name = os.path.basename(args.model_x)
    y_name = os.path.basename(args.model_y)
    pairs = []
    for case in cases:
        for k in range(args.samples):
            x_text, y_text = x_out[(case["id"], k)], y_out[(case["id"], k)]
            x_left = rng.random() < 0.5
            pairs.append({
                "pair_id": "%s#%d" % (case["id"], k),
                "task": case["task"],
                "inner": case["inner"],
                "left": x_text if x_left else y_text,
                "right": y_text if x_left else x_text,
                "left_model": x_name if x_left else y_name,
                "right_model": y_name if x_left else x_name,
            })
    with open(args.out, "w", encoding="utf-8") as handle:
        for pair in pairs:
            handle.write(json.dumps(pair, ensure_ascii=False) + "\n")
    empties = sum(1 for p in pairs if not p["left"].strip() or not p["right"].strip())
    print("wrote %d pairs -> %s (%d with an empty side)" % (len(pairs), args.out, empties))


def _judge_once(endpoint, judge_model, inner, left, right):
    body = {
        "messages": [{"role": "user",
                      "content": JUDGE_PROMPT % (inner, left, right)}],
        "temperature": 0,
        "max_tokens": 4096,  # headroom for judges that think before answering
    }
    if judge_model:
        body["model"] = judge_model
    reply = post_json(endpoint.rstrip("/") + "/v1/chat/completions", body)
    text = reply["choices"][0]["message"]["content"] or ""
    # thinking-style judges wrap reasoning in <think>...</think> before the JSON
    if "</think>" in text:
        text = text.split("</think>")[-1]
    try:
        start, end = text.index("{"), text.rindex("}") + 1
        verdict = json.loads(text[start:end])
        winner = str(verdict.get("winner", "")).strip()
        reason = str(verdict.get("reason", ""))[:200]
    except (ValueError, KeyError):
        winner, reason = "", text[:200]
    if winner not in ("L", "R", "tie"):
        winner = "invalid"
    return winner, reason


def consolidate(first: str, swapped: str) -> str:
    """Position-bias control: each pair is judged twice with sides swapped.
    A model only wins if both orders agree on it; anything inconsistent
    (including tie+win splits) scores as a tie."""
    if "invalid" in (first, swapped):
        return "invalid"
    # map the swapped verdict back into the original orientation
    swapped_orig = {"L": "R", "R": "L", "tie": "tie"}[swapped]
    return first if first == swapped_orig and first != "tie" else "tie"


def cmd_judge(args):
    pairs = [json.loads(line) for line in open(args.pairs, encoding="utf-8")]
    if args.limit:
        pairs = pairs[: args.limit]
    with open(args.out, "w", encoding="utf-8") as handle:
        for index, pair in enumerate(pairs, 1):
            first, reason1 = _judge_once(args.endpoint, args.judge_model,
                                         pair["inner"], pair["left"], pair["right"])
            swapped, reason2 = _judge_once(args.endpoint, args.judge_model,
                                           pair["inner"], pair["right"], pair["left"])
            winner = consolidate(first, swapped)
            handle.write(json.dumps({
                "pair_id": pair["pair_id"], "winner": winner,
                "orders": [first, swapped],
                "reason": "%s / %s" % (reason1, reason2),
            }, ensure_ascii=False) + "\n")
            print("[%2d/%2d] %-38s %s (%s/%s)" % (
                index, len(pairs), pair["pair_id"], winner, first, swapped))
    print("wrote judgments -> %s" % args.out)


def sign_test_p(wins_a: int, wins_b: int) -> float:
    """Two-sided exact sign test over non-tie pairs."""
    n = wins_a + wins_b
    if n == 0:
        return 1.0
    k = min(wins_a, wins_b)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def cmd_report(args):
    pairs = {p["pair_id"]: p for line in open(args.pairs, encoding="utf-8")
             for p in [json.loads(line)]}
    judgments = [json.loads(line) for line in open(args.judgments, encoding="utf-8")]

    models = sorted({p["left_model"] for p in pairs.values()}
                    | {p["right_model"] for p in pairs.values()})
    assert len(models) == 2, models
    tally = {}  # (task|"ALL", model|"tie"|"invalid") -> count
    for judgment in judgments:
        pair = pairs[judgment["pair_id"]]
        winner = judgment["winner"]
        outcome = (pair["%s_model" % ("left" if winner == "L" else "right")]
                   if winner in ("L", "R") else winner)
        for scope in ("ALL", pair["task"]):
            tally[(scope, outcome)] = tally.get((scope, outcome), 0) + 1

    print("judged pairs: %d" % len(judgments))
    print("%-18s %-42s %5s" % ("scope", "model", "wins"))
    for scope in ("ALL",) + TASKS:
        for outcome in models + ["tie", "invalid"]:
            count = tally.get((scope, outcome), 0)
            if count or outcome in models:
                print("%-18s %-42s %5d" % (scope, outcome, count))
        print()
    wins_a = tally.get(("ALL", models[0]), 0)
    wins_b = tally.get(("ALL", models[1]), 0)
    p = sign_test_p(wins_a, wins_b)
    leader = models[0] if wins_a >= wins_b else models[1]
    print("sign test (non-tie pairs, two-sided): p = %.4f%s" % (
        p, "  -- %s leads" % leader if wins_a != wins_b else ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    gen = sub.add_parser("generate", help="produce blinded L/R pairs from two GGUFs")
    gen.add_argument("--model-x", required=True)
    gen.add_argument("--template-x", choices=sorted(prompts.TEMPLATES), required=True)
    gen.add_argument("--model-y", required=True)
    gen.add_argument("--template-y", choices=sorted(prompts.TEMPLATES), required=True)
    gen.add_argument("--samples", type=int, default=2, help="samples per case per model")
    gen.add_argument("--seed", type=int, default=3407, help="blinding shuffle seed")
    gen.add_argument("--out", default="finetune/naturalness-pairs.jsonl")
    gen.set_defaults(func=cmd_generate)

    judge = sub.add_parser("judge", help="judge pairs via an OpenAI-compatible endpoint")
    judge.add_argument("--pairs", default="finetune/naturalness-pairs.jsonl")
    judge.add_argument("--endpoint", required=True, help="base URL, e.g. http://127.0.0.1:8080")
    judge.add_argument("--judge-model", default=None)
    judge.add_argument("--limit", type=int, default=None)
    judge.add_argument("--out", default="finetune/naturalness-judgments.jsonl")
    judge.set_defaults(func=cmd_judge)

    rep = sub.add_parser("report", help="tally judgments + sign test")
    rep.add_argument("--pairs", default="finetune/naturalness-pairs.jsonl")
    rep.add_argument("--judgments", default="finetune/naturalness-judgments.jsonl")
    rep.set_defaults(func=cmd_report)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
