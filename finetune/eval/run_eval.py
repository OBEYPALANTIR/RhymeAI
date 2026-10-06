#!/usr/bin/env python3
"""Desktop eval harness for RhymeAI's on-device Gemma models.

Replays the app's exact local-model requests against a GGUF served by
llama.cpp's llama-server, and scores the raw outputs programmatically.
Intended as the before/after gate for LoRA fine-tunes.

Each request is the inner prompt (prompts.py, a parity port of AIService.kt)
wrapped in the app's on-device envelope (prompts.app_prompt, the port of
GGUFModelService.gemmaPrompt) and posted as raw text to /completion, which
applies no chat template. The text carries no <bos>: for a raw prompt
llama-server adds one when the GGUF sets tokenizer.ggml.add_bos_token, exactly
as llama.cpp does in the app (a literal <bos> would make two). --envelope
gemma4 (default) is what the app sends the shipped E2B/E4B models; --envelope
legacy is for imported Gemma 1-3n GGUFs and reproduces the harness's
pre-Gemma-4 requests. The served chat template is checked against the choice.

Usage:
  python3 finetune/eval/run_eval.py --model /path/to/model.gguf \
      [--envelope gemma4|legacy] [--cases N] [--out report.json]

Requires llama-server (Homebrew llama.cpp: /opt/homebrew/bin/llama-server).
Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from eval import cases as cases_mod
    from eval import prompts, scoring
else:
    from . import cases as cases_mod
    from . import prompts, scoring

LLAMA_SERVER = "/opt/homebrew/bin/llama-server"

# Sampler contract shared with the mobile apps (iOS LocalModelService /
# Android LocalModelService: ctx 2048; temp 0.8, top-k 40, top-p 0.95).
CTX_SIZE = 2048
TEMPERATURE = 0.8
TOP_K = 40
TOP_P = 0.95
N_PREDICT = 256

HEALTH_TIMEOUT_S = 300
REQUEST_TIMEOUT_S = 600


# ---------------------------------------------------------------------------
# Case preparation: turn a case dict into (inner prompt, scoring context)
# ---------------------------------------------------------------------------

def request_text(prepared, envelope):
    """The raw /completion prompt: the app's envelope around the inner prompt."""
    return prompts.app_prompt(prepared["user_prompt"], envelope)


def prepare_case(case):
    task = case["task"]
    prepared = {"case": case, "task": task, "id": case["id"]}

    if task == "suggestions":
        section_ref = None
        if case["section"] is not None:
            want_type, want_ordinal = case["section"]
            refs = prompts.parse_section_map(case["lyrics"])
            section_ref = next(
                (r for r in refs if r.type == want_type and r.ordinal == want_ordinal),
                None,
            )
            if section_ref is None:
                raise ValueError(
                    "case %s: section %s not found in lyrics" % (case["id"], case["section"])
                )
        chorus_ends = prompts.first_chorus_end_words(case["lyrics"])
        constraint = prompts.suggestion_rhyme_constraint(
            case["target_rhyme_line"],
            case["rhyme_type"],
            section_ref=section_ref,
            chorus_end_words=chorus_ends,
        )
        prepared["constraint"] = constraint
        prepared["user_prompt"] = prompts.build_suggestions_prompt(
            theme=case["theme"],
            lyrics=case["lyrics"],
            target_rhyme_line=case["target_rhyme_line"],
            rhyme_type=case["rhyme_type"],
            rhyme_scheme=case["rhyme_scheme"],
            current_letter=case["current_letter"],
            current_section=case["current_section"],
            complexity=case["complexity"],
            use_whole_song_context=case["use_whole_song_context"],
            constraint=constraint,
        )
    elif task == "rewrite_passage":
        prepared["user_prompt"] = prompts.build_rewrite_prompt(
            action=case["action"],
            lyrics=case["lyrics"],
            selection=case["selection"],
            current_section=case["current_section"],
        )
    elif task == "rewrite_word":
        selection_start = cases_mod.selection_start_for(case)
        prepared["selection_start"] = selection_start
        prepared["user_prompt"] = prompts.build_rewrite_prompt(
            action=case["action"],
            lyrics=case["lyrics"],
            selection=case["selection"],
            current_section=case["current_section"],
            selection_start=selection_start,
            rejected_candidates=case["rejected"],
        )
    elif task == "synonyms":
        prepared["user_prompt"] = prompts.build_synonyms_prompt(
            word=case["word"].strip(),
            line_context=case["line_context"],
            limit=case["limit"],
        )
    else:
        raise ValueError("unknown task: %s" % task)
    return prepared


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def score_case(prepared, output_text):
    case = prepared["case"]
    task = prepared["task"]
    result = {}

    if task == "suggestions":
        fmt = scoring.validate_suggestions(
            output_text, prompts.SUGGESTION_COUNT, case["lyrics"]
        )
        result["format"] = {
            "passed": fmt["passed"],
            "line_count": len(fmt["lines"]),
            "violations": [
                {"line_index": idx, "violations": v} for idx, v in fmt["violations"]
            ],
        }
        constraint = prepared.get("constraint")
        if constraint is not None:
            matches = scoring.find_rhymes(constraint.target_word)
            per_line = []
            for line in fmt["lines"]:
                end = scoring.line_end_word(line)
                if end and end in constraint.candidate_words:
                    tier = "candidate"
                elif scoring.rhyme_tier(line, matches) > 0:
                    tier = "rhymes"
                else:
                    tier = "miss"
                per_line.append({"line": line, "end_word": end, "tier": tier})
            result["rhyme"] = {
                "target_word": constraint.target_word,
                "per_line": per_line,
                "candidate": sum(1 for p in per_line if p["tier"] == "candidate"),
                "rhymes": sum(1 for p in per_line if p["tier"] == "rhymes"),
                "miss": sum(1 for p in per_line if p["tier"] == "miss"),
            }
    elif task == "rewrite_passage":
        fmt = scoring.validate_rewrite_passage(output_text, case["selection"])
        result["format"] = {
            "passed": fmt["passed"],
            "violations": fmt["violations"],
            "text": fmt["text"],
        }
    elif task == "rewrite_word":
        fmt = scoring.validate_single_word_rewrite(
            output_text, case["selection"], case["rejected"]
        )
        result["format"] = {
            "passed": fmt["passed"],
            "violations": fmt["violations"],
            "word": fmt["word"],
        }
        if case["action"] == "HARDER_RHYME" and fmt["word"]:
            result["rhyme"] = {
                "target_word": case["selection"],
                "is_perfect_rhyme": scoring.is_perfect_rhyme(case["selection"], fmt["word"]),
            }
    elif task == "synonyms":
        fmt = scoring.validate_synonyms(output_text, case["word"], case["limit"])
        result["format"] = {
            "passed": fmt["passed"],
            "word_count": len(fmt["words"]),
            "violations": [
                {"line_index": idx, "violations": v} for idx, v in fmt["violations"]
            ],
            "words": fmt["words"],
        }
    return result


# ---------------------------------------------------------------------------
# llama-server management
# ---------------------------------------------------------------------------

def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start_server(model_path, port, log_path):
    if not os.path.exists(LLAMA_SERVER):
        sys.exit("llama-server not found at %s (brew install llama.cpp)" % LLAMA_SERVER)
    if not os.path.exists(model_path):
        sys.exit("model not found: %s" % model_path)
    cmd = [
        LLAMA_SERVER,
        "-m", model_path,
        "--ctx-size", str(CTX_SIZE),
        "--host", "127.0.0.1",
        "--port", str(port),
        "--n-gpu-layers", "99",
    ]
    log_handle = open(log_path, "w")
    process = subprocess.Popen(
        cmd, stdout=log_handle, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    return process, log_handle


def wait_for_health(port, process, timeout_s=HEALTH_TIMEOUT_S):
    deadline = time.time() + timeout_s
    url = "http://127.0.0.1:%d/health" % port
    while time.time() < deadline:
        if process.poll() is not None:
            sys.exit("llama-server exited early (code %s) — see server log" % process.returncode)
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(1)
    sys.exit("llama-server did not become healthy within %ds" % timeout_s)


def stop_server(process, log_handle):
    if process.poll() is None:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                process.kill()
            process.wait()
    log_handle.close()


def envelope_mismatch(base_url, envelope):
    """None when the served chat template uses `envelope`'s markers (the
    template half of GGUFPromptFormat.resolve, read from llama-server's
    /props, which does not report the architecture); otherwise why not."""
    try:
        with urllib.request.urlopen(base_url.rstrip("/") + "/props", timeout=30) as response:
            template = json.loads(response.read().decode("utf-8")).get("chat_template") or ""
    except (urllib.error.URLError, OSError, ValueError) as error:
        return "could not read the chat template from %s/props (%s)" % (base_url, error)
    served = prompts.template_envelope(template)
    if served is envelope:
        return None
    return ("the served chat template uses %s turn markers, so the app would not send "
            "the %s envelope to this model" % (served.name if served else "no supported",
                                               envelope.name))


def completion(port, prompt, stop):
    """POST the raw request text to /completion (no chat template)."""
    body = json.dumps({
        "prompt": prompt,
        "n_predict": N_PREDICT,
        "temperature": TEMPERATURE,
        "top_k": TOP_K,
        "top_p": TOP_P,
        "stop": stop,
        "cache_prompt": False,
    }).encode("utf-8")
    request = urllib.request.Request(
        "http://127.0.0.1:%d/completion" % port,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.time()
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
        payload = json.loads(response.read().decode("utf-8"))
    latency = time.time() - started
    return payload, latency


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def summarize(results):
    by_task = {}
    for entry in results:
        by_task.setdefault(entry["task"], []).append(entry)

    print()
    print("=" * 78)
    print("SUMMARY")
    print("=" * 78)
    header = "%-18s %5s %10s %26s %9s %8s" % (
        "task", "n", "fmt pass", "rhyme lines (cand/rhy/miss)", "avg s", "avg tok"
    )
    print(header)
    print("-" * len(header))
    for task in ("suggestions", "rewrite_passage", "rewrite_word", "synonyms"):
        entries = by_task.get(task, [])
        if not entries:
            continue
        n = len(entries)
        fmt_pass = sum(1 for e in entries if e["score"]["format"]["passed"])
        avg_latency = sum(e["latency_s"] for e in entries) / n
        avg_tokens = sum(e["tokens_predicted"] for e in entries) / n

        rhyme_col = "-"
        rhyme_entries = [e for e in entries if "rhyme" in e["score"] and "per_line" in e["score"]["rhyme"]]
        if rhyme_entries:
            candidate = sum(e["score"]["rhyme"]["candidate"] for e in rhyme_entries)
            rhymes = sum(e["score"]["rhyme"]["rhymes"] for e in rhyme_entries)
            miss = sum(e["score"]["rhyme"]["miss"] for e in rhyme_entries)
            total = candidate + rhymes + miss
            if total:
                rhyme_col = "%d/%d/%d (%.0f%% hit)" % (
                    candidate, rhymes, miss, 100.0 * (candidate + rhymes) / total
                )
        elif task == "rewrite_word":
            harder = [e for e in entries if "rhyme" in e["score"]]
            if harder:
                hits = sum(1 for e in harder if e["score"]["rhyme"]["is_perfect_rhyme"])
                rhyme_col = "harder-rhyme %d/%d perfect" % (hits, len(harder))

        print("%-18s %5d %9.0f%% %26s %9.2f %8.0f" % (
            task, n, 100.0 * fmt_pass / n, rhyme_col, avg_latency, avg_tokens
        ))
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Replay RhymeAI's exact on-device prompts against a GGUF "
                    "via llama-server and score the outputs.",
    )
    parser.add_argument("--model", required=True, help="Path to the .gguf model file")
    parser.add_argument("--cases", type=int, default=None,
                        help="Only run the first N cases (default: all)")
    parser.add_argument("--out", default="report.json",
                        help="Path for the JSON report (default: report.json)")
    parser.add_argument("--envelope", choices=sorted(prompts.ENVELOPE_OPTIONS),
                        default="gemma4",
                        help="Turn envelope (default gemma4: what the app sends the "
                             "shipped E2B/E4B models; legacy: imported Gemma 1-3n "
                             "GGUFs and the pre-Gemma-4 harness requests)")
    args = parser.parse_args()
    envelope = prompts.ENVELOPE_OPTIONS[args.envelope]
    stop = [envelope.end_of_turn]

    all_cases = cases_mod.CASES
    selected = all_cases[: args.cases] if args.cases else all_cases

    # Prepare all prompts up front (also fails fast on bad cases and warms the
    # pronunciation index).
    prepared_cases = [prepare_case(case) for case in selected]

    port = free_port()
    log_path = os.path.splitext(args.out)[0] + ".server.log"
    print("starting llama-server on port %d (log: %s)" % (port, log_path))
    process, log_handle = start_server(args.model, port, log_path)

    results = []
    try:
        wait_for_health(port, process)
        envelope_check = envelope_mismatch("http://127.0.0.1:%d" % port, envelope)
        if envelope_check:
            print("WARNING: %s" % envelope_check)
        print("server healthy; running %d cases with the %s envelope"
              % (len(prepared_cases), envelope.name))
        for index, prepared in enumerate(prepared_cases, 1):
            prompt = request_text(prepared, envelope)
            payload, latency = completion(port, prompt, stop)
            output_text = payload.get("content", "")
            tokens = payload.get("tokens_predicted", 0)
            score = score_case(prepared, output_text)
            passed = score["format"]["passed"]
            print("[%2d/%2d] %-32s %s  (%.1fs, %d tok)" % (
                index, len(prepared_cases), prepared["id"],
                "PASS" if passed else "FAIL", latency, tokens,
            ))
            results.append({
                "id": prepared["id"],
                "task": prepared["task"],
                "prompt_chars": len(prompt),
                "latency_s": round(latency, 3),
                "tokens_predicted": tokens,
                "output": output_text,
                "score": score,
            })
    finally:
        stop_server(process, log_handle)
        print("llama-server stopped")

    report = {
        "model": args.model,
        "envelope": envelope.name,
        "envelope_check": envelope_check or "matches the served chat template",
        "sampler": {
            "ctx_size": CTX_SIZE,
            "temperature": TEMPERATURE,
            "top_k": TOP_K,
            "top_p": TOP_P,
            "n_predict": N_PREDICT,
            "stop": stop,
        },
        "case_count": len(results),
        "results": results,
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, ensure_ascii=False)
    print("report written to %s" % args.out)

    summarize(results)


if __name__ == "__main__":
    main()
