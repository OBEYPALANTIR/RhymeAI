#!/usr/bin/env python3
"""Desktop replay harness for native RhymeAI local-model contract exports.

Consumes prompts and generation provenance emitted by the production native
builders, runs a controlled desktop replay through llama-server, and scores the
raw outputs programmatically. The report states the native behavior that this
desktop engine cannot reproduce exactly.

Usage:
  python3 finetune/eval/run_eval.py --model /path/to/model.gguf \
      --contracts ios.json android.json --replay-seed 3407 \
      [--cases N] [--out report.json]

Requires llama-server (Homebrew llama.cpp: /opt/homebrew/bin/llama-server).
Stdlib only.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from eval import cases as cases_mod
    from eval import heldout, native_contract, prompts, scoring
else:
    from . import cases as cases_mod
    from . import heldout, native_contract, prompts, scoring

LLAMA_SERVER = "/opt/homebrew/bin/llama-server"

HEALTH_TIMEOUT_S = 300
REQUEST_TIMEOUT_S = 600


def replay_seed_argument(value):
    try:
        return native_contract.validate_replay_seed(int(value))
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def positive_integer_argument(value):
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def append_native_chunk(output, chunk, length_limit, length_unit):
    previous_length = native_contract.response_length(output, length_unit)
    output += chunk
    current_length = native_contract.response_length(output, length_unit)
    boundary_reached = length_limit is not None and current_length >= length_limit
    return output, previous_length, current_length, boundary_reached


def response_boundary_passed(output_length, length_limit, boundary):
    if length_limit is None or output_length <= length_limit:
        return True
    return (
        boundary["enforcedDuringStreaming"]
        and boundary["reached"]
        and boundary["previousValue"] < length_limit <= boundary["value"]
        and boundary["value"] == output_length
    )


def record_deadline_timeout(deadline_ms, final_payload):
    if deadline_ms is None:
        raise TimeoutError
    final_payload["stop_type"] = "deadline"


def remaining_deadline_seconds(started, deadline_ms, current):
    return deadline_ms / 1000 - (current - started)


def contract_file_evidence(paths):
    return [
        {"path": path, "sha256": native_contract.model_sha256(path)}
        for path in paths
    ]


def prepare_output_paths(output_path):
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    return os.path.splitext(output_path)[0] + ".server.log"


def termination_passed(payload):
    return (
        payload["terminal_received"]
        and payload.get("stop_type") not in {"deadline", "error"}
    )


def expire_deadline_socket(expired, socket_ref):
    expired.set()
    active_socket = socket_ref[0]
    if active_socket is not None:
        try:
            active_socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        active_socket.close()


# ---------------------------------------------------------------------------
# Case preparation: turn a case dict into (prompt, scoring context)
# ---------------------------------------------------------------------------

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
        prepared["prompt"] = prompts.build_suggestions_prompt(
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
        prepared["prompt"] = prompts.build_rewrite_prompt(
            action=case["action"],
            lyrics=case["lyrics"],
            selection=case["selection"],
            current_section=case["current_section"],
        )
    elif task == "rewrite_word":
        selection_start = cases_mod.selection_start_for(case)
        prepared["selection_start"] = selection_start
        prepared["prompt"] = prompts.build_rewrite_prompt(
            action=case["action"],
            lyrics=case["lyrics"],
            selection=case["selection"],
            current_section=case["current_section"],
            selection_start=selection_start,
            rejected_candidates=case["rejected"],
        )
    elif task == "synonyms":
        prepared["prompt"] = prompts.build_synonyms_prompt(
            word=case["word"].strip(),
            line_context=case["line_context"],
            limit=case["limit"],
        )
    else:
        raise ValueError("unknown task: %s" % task)
    return prepared


def prepare_contract(record):
    case = native_contract.scoring_case(record)
    prepared = {
        "case": case,
        "task": case["task"],
        "id": case["id"],
        "prompt": record["prompt"]["renderedText"],
        "contract": record,
    }
    if case["task"] == "suggestions" and case["target_rhyme_line"]:
        prepared["constraint"] = prompts.suggestion_rhyme_constraint(
            case["target_rhyme_line"], case["rhyme_type"]
        )
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
            required_tier = 2 if case["rhyme_type"] == "PERFECT" else 1
            per_line = []
            for line in fmt["lines"]:
                end = scoring.line_end_word(line)
                actual_tier = scoring.rhyme_tier(line, matches)
                if end and end in constraint.candidate_words and actual_tier >= required_tier:
                    tier = "candidate"
                elif actual_tier >= required_tier:
                    tier = "rhymes"
                else:
                    tier = "miss"
                per_line.append({
                    "line": line,
                    "end_word": end,
                    "tier": tier,
                    "rhyme_tier": actual_tier,
                })
            result["rhyme"] = {
                "target_word": constraint.target_word,
                "requested_type": case["rhyme_type"],
                "required_tier": required_tier,
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


def score_passed(score):
    heldout_score = score.get("heldout")
    heldout_passed = heldout_score is None or (
        heldout_score["lexical_validity_passed"]
        and heldout_score["rejection_passed"]
        and heldout_score["fixture_pos_and_context_passed"]
    )
    rhyme = score.get("rhyme")
    if rhyme is None:
        rhyme_passed = True
    elif "per_line" in rhyme:
        rhyme_passed = rhyme["miss"] == 0
    else:
        rhyme_passed = rhyme["is_perfect_rhyme"]
    return (
        score["format"]["passed"]
        and score["response_length"]["passed"]
        and score.get("termination", {"passed": True})["passed"]
        and heldout_passed
        and rhyme_passed
    )


# ---------------------------------------------------------------------------
# llama-server management
# ---------------------------------------------------------------------------

def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start_server(model_path, port, log_path, context_length):
    if not os.path.exists(LLAMA_SERVER):
        sys.exit("llama-server not found at %s (brew install llama.cpp)" % LLAMA_SERVER)
    if not os.path.exists(model_path):
        sys.exit("model not found: %s" % model_path)
    cmd = [
        LLAMA_SERVER,
        "-m", model_path,
        "--ctx-size", str(context_length),
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


def completion(port, contract, replay_seed):
    """Stream one replay and stop at the native response-length boundary."""
    request_body = native_contract.completion_body(contract, replay_seed=replay_seed)
    request_body["stream"] = True
    body = json.dumps(request_body).encode("utf-8")
    started = time.monotonic()
    deadline_ms = contract["generation"]["termination"]["deadlineMs"]
    timeout = deadline_ms / 1000 if deadline_ms is not None else REQUEST_TIMEOUT_S
    termination = contract["generation"]["termination"]
    length_limit = termination["maximumResponseLength"]
    length_unit = termination["responseLengthUnit"]
    output = ""
    previous_length = 0
    boundary_reached = False
    final_payload = {}
    predicted_tokens = None
    content_chunks = 0
    terminal_received = False
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    deadline_expired = threading.Event()
    deadline_socket = [None]
    deadline_timer = None
    try:
        connection.connect()
        deadline_socket[0] = connection.sock
        if deadline_ms is not None:
            remaining = remaining_deadline_seconds(started, deadline_ms, time.monotonic())
            if remaining <= 0:
                raise TimeoutError
            deadline_timer = threading.Timer(
                remaining, expire_deadline_socket, args=(deadline_expired, deadline_socket)
            )
            deadline_timer.daemon = True
            deadline_timer.start()
        connection.request(
            "POST", "/completion", body=body,
            headers={"Content-Type": "application/json"},
        )
        if deadline_ms is not None:
            remaining = remaining_deadline_seconds(started, deadline_ms, time.monotonic())
            if remaining <= 0:
                raise TimeoutError
            connection.sock.settimeout(remaining)
        response = connection.getresponse()
        content_type = response.headers.get_content_type()
        stream_socket = response.fp.raw._sock
        deadline_socket[0] = stream_socket
        while True:
            if deadline_ms is not None:
                remaining = remaining_deadline_seconds(started, deadline_ms, time.monotonic())
                if remaining <= 0:
                    final_payload["stop_type"] = "deadline"
                    break
                stream_socket.settimeout(remaining)
            raw_line = response.readline()
            if not raw_line:
                break
            if (
                deadline_ms is not None
                and remaining_deadline_seconds(started, deadline_ms, time.monotonic()) <= 0
            ):
                final_payload["stop_type"] = "deadline"
                break
            line = raw_line.decode("utf-8").strip()
            if not line:
                continue
            if content_type == "text/event-stream":
                if not line.startswith("data:"):
                    continue
                line = line[5:].strip()
            if line == "[DONE]":
                terminal_received = True
                break
            event = json.loads(line)
            final_payload.update(event)
            reported_tokens = event.get("tokens_predicted")
            if isinstance(reported_tokens, int) and not isinstance(reported_tokens, bool):
                predicted_tokens = reported_tokens
            chunk = event.get("content", "")
            if chunk:
                content_chunks += 1
                output, previous_length, current_length, crossed_boundary = append_native_chunk(
                    output, chunk, length_limit, length_unit
                )
                if crossed_boundary:
                    boundary_reached = True
                    terminal_received = True
                    final_payload["stop_type"] = "maximumResponseLength"
                    break
            if event.get("stop"):
                terminal_received = True
                break
    except (TimeoutError, OSError, http.client.HTTPException):
        if (
            deadline_ms is None
            or (
                not deadline_expired.is_set()
                and remaining_deadline_seconds(started, deadline_ms, time.monotonic()) > 0
            )
        ):
            raise
        record_deadline_timeout(deadline_ms, final_payload)
    finally:
        if deadline_timer is not None:
            deadline_timer.cancel()
        connection.close()
    if deadline_expired.is_set():
        record_deadline_timeout(deadline_ms, final_payload)
    latency = time.monotonic() - started
    final_payload["content"] = output
    final_payload["tokens_predicted"] = predicted_tokens
    final_payload["content_chunks"] = content_chunks
    final_payload["terminal_received"] = terminal_received
    final_payload["replay_boundary"] = {
        "enforcedDuringStreaming": True,
        "reached": boundary_reached,
        "previousValue": previous_length,
        "value": native_contract.response_length(output, length_unit),
        "limit": length_limit,
        "unit": length_unit,
    }
    return final_payload, latency


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def summarize(results):
    by_platform_task = {}
    for entry in results:
        key = (entry["platform"], entry["task"])
        by_platform_task.setdefault(key, []).append(entry)

    print()
    print("=" * 118)
    print("SUMMARY")
    print("=" * 118)
    header = "%-8s %-18s %5s %10s %12s %11s %26s %9s %9s" % (
        "platform", "task", "n", "fmt pass", "fixture pass", "human",
        "rhyme lines (cand/rhy/miss)", "avg s", "avg tok",
    )
    print(header)
    print("-" * len(header))
    for platform in ("ios", "android"):
        for task in ("suggestions", "rewrite_passage", "rewrite_word", "synonyms"):
            entries = by_platform_task.get((platform, task), [])
            if not entries:
                continue
            n = len(entries)
            fmt_pass = sum(1 for e in entries if e["score"]["format"]["passed"])
            avg_latency = sum(e["latency_s"] for e in entries) / n
            known_tokens = [
                e["tokens_predicted"] for e in entries
                if e["tokens_predicted"] is not None
            ]
            avg_tokens = (
                "%.0f" % (sum(known_tokens) / len(known_tokens))
                if known_tokens else "unknown"
            )
            fixture_entries = [e["score"]["heldout"] for e in entries if "heldout" in e["score"]]
            if fixture_entries:
                fixture_passes = sum(
                    1 for score in fixture_entries
                    if score["lexical_validity_passed"]
                    and score["rejection_passed"]
                    and score["fixture_pos_and_context_passed"]
                )
                fixture_col = "%d/%d" % (fixture_passes, len(fixture_entries))
                human_col = "unverified"
            else:
                fixture_col = "-"
                human_col = "-"

            rhyme_col = "-"
            rhyme_entries = [
                e for e in entries
                if "rhyme" in e["score"] and "per_line" in e["score"]["rhyme"]
            ]
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
                    hits = sum(
                        1 for e in harder if e["score"]["rhyme"]["is_perfect_rhyme"]
                    )
                    rhyme_col = "harder-rhyme %d/%d perfect" % (hits, len(harder))

            print("%-8s %-18s %5d %9.0f%% %12s %11s %26s %9.2f %9s" % (
                platform, task, n, 100.0 * fmt_pass / n,
                fixture_col, human_col, rhyme_col, avg_latency, avg_tokens,
            ))
    print()


def evaluation_passed(results):
    return bool(results) and all(result["passed"] for result in results)


def validate_heldout_coverage(case_manifest, heldout_fixtures):
    expected = {
        case["caseId"]
        for case in case_manifest["cases"]
        if case["caseId"].startswith("heldout_")
    }
    actual = set(heldout_fixtures)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ValueError(
            "held-out fixtures differ from manifest (missing=%s extra=%s)"
            % (missing, extra)
        )


def exit_on_evaluation_failure(passed):
    if not passed:
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Run a controlled desktop replay of native RhymeAI contract exports against a "
                    "GGUF via llama-server and score the outputs.",
    )
    parser.add_argument("--model", required=True, help="Path to the .gguf model file")
    parser.add_argument("--contracts", nargs="+", required=True,
                        help="Native JSON/JSONL export file(s); JSON may contain one record or an array")
    parser.add_argument(
        "--replay-seed",
        type=replay_seed_argument,
        required=True,
        help="Explicit non-negative seed for this controlled desktop replay; native seed provenance is preserved separately",
    )
    parser.add_argument(
        "--case-manifest",
        default=os.path.join(os.path.dirname(__file__), "native-contract-cases-v1.json"),
        help="Frozen shared native request manifest",
    )
    parser.add_argument(
        "--heldout-fixtures",
        default=os.path.join(os.path.dirname(__file__), "heldout-cases-v1.json"),
        help="Held-out semantic fixture file (default: eval/heldout-cases-v1.json)",
    )
    parser.add_argument("--cases", type=positive_integer_argument, default=None,
                        help="Run the first N manifest cases on both platforms (default: all)")
    parser.add_argument("--out", default="report.json",
                        help="Path for the JSON report (default: report.json)")
    args = parser.parse_args()

    contract_files = contract_file_evidence(args.contracts)
    case_manifest_sha256 = native_contract.model_sha256(args.case_manifest)
    heldout_fixture_sha256 = native_contract.model_sha256(args.heldout_fixtures)
    contracts = native_contract.load_contracts(args.contracts, exact=True)
    case_manifest = native_contract.load_case_manifest(args.case_manifest)
    native_contract.validate_manifest_records(contracts, case_manifest)
    native_contract.validate_platform_pairs(contracts)
    heldout_fixtures = heldout.load(args.heldout_fixtures)
    validate_heldout_coverage(case_manifest, heldout_fixtures)
    if (
        contract_files != contract_file_evidence(args.contracts)
        or case_manifest_sha256 != native_contract.model_sha256(args.case_manifest)
        or heldout_fixture_sha256 != native_contract.model_sha256(args.heldout_fixtures)
    ):
        sys.exit("evaluation inputs changed while loading")
    if args.cases is not None:
        selected_ids = {
            case["caseId"] for case in case_manifest["cases"][: args.cases]
        }
        selected = [record for record in contracts if record["caseId"] in selected_ids]
    else:
        selected = contracts
    actual_model_sha = native_contract.model_sha256(args.model)
    expected_model_shas = {record["modelSha256"] for record in selected}
    if expected_model_shas != {actual_model_sha}:
        sys.exit("model SHA-256 does not match every native contract: %s" % actual_model_sha)
    context_lengths = {record["generation"]["contextLength"] for record in selected}
    if len(context_lengths) != 1:
        sys.exit("native contracts must use one contextLength per replay run")
    prepared_cases = [prepare_contract(record) for record in selected]

    port = free_port()
    log_path = prepare_output_paths(args.out)
    print("starting llama-server on port %d (log: %s)" % (port, log_path))
    process, log_handle = start_server(args.model, port, log_path, context_lengths.pop())

    results = []
    try:
        wait_for_health(port, process)
        if native_contract.model_sha256(args.model) != actual_model_sha:
            sys.exit("model changed while llama-server was loading")
        print("server healthy; running %d cases" % len(prepared_cases))
        for index, prepared in enumerate(prepared_cases, 1):
            contract = prepared["contract"]
            payload, latency = completion(port, contract, args.replay_seed)
            output_text = payload.get("content", "")
            tokens = payload.get("tokens_predicted")
            score = score_case(prepared, output_text)
            fixture = heldout_fixtures.get(prepared["id"])
            if fixture is not None:
                heldout.validate_contract(fixture, contract)
                candidates = heldout.candidates_from_score(prepared["task"], score)
                score["heldout"] = heldout.score_candidates(candidates, fixture)
            termination = contract["generation"]["termination"]
            output_length = native_contract.response_length(
                output_text, termination["responseLengthUnit"]
            )
            length_limit = termination["maximumResponseLength"]
            boundary = payload["replay_boundary"]
            length_passed = response_boundary_passed(output_length, length_limit, boundary)
            score["response_length"] = {
                "passed": length_passed,
                "value": output_length,
                "limit": length_limit,
                "unit": termination["responseLengthUnit"],
                "enforced_during_streaming": boundary["enforcedDuringStreaming"],
                "boundary_reached": boundary["reached"],
                "boundary_previous_value": boundary["previousValue"],
            }
            score["termination"] = {
                "passed": termination_passed(payload),
                "reason": payload.get("stop_type"),
                "terminal_received": payload["terminal_received"],
            }
            passed = score_passed(score)
            print("[%2d/%2d] %-32s %s  (%.1fs, %s tok)" % (
                index, len(prepared_cases), prepared["id"],
                "PASS" if passed else "FAIL", latency,
                tokens if tokens is not None else "unknown",
            ))
            results.append({
                "id": prepared["id"],
                "task": prepared["task"],
                "platform": contract["platform"],
                "passed": passed,
                "source_sha": contract["sourceSha"],
                "model_sha256": contract["modelSha256"],
                "prompt_sha256": contract["prompt"]["renderedTextSha256"],
                "native_generation": contract["generation"],
                "native_runtime": contract["runtime"],
                "controlled_replay_seed": {
                    "policy": "fixed",
                    "value": args.replay_seed,
                },
                "prompt_chars": len(prepared["prompt"]),
                "latency_s": round(latency, 3),
                "tokens_predicted": tokens,
                "tokens_predicted_provenance": (
                    "serverReported" if tokens is not None else "unavailable"
                ),
                "stream_content_chunks": payload["content_chunks"],
                "replay_stop_type": payload.get("stop_type"),
                "output": output_text,
                "score": score,
            })
    finally:
        stop_server(process, log_handle)
        print("llama-server stopped")

    report = {
        "model": args.model,
        "model_sha256": actual_model_sha,
        "llama_server": LLAMA_SERVER,
        "replay_evidence_kind": "controlledReplay",
        "controlled_replay_seed": {
            "policy": "fixed",
            "value": args.replay_seed,
        },
        "replay_limitations": [
            "Native prompt bytes and reported settings are preserved, but llama-server is not the native engine.",
            "Native tokenizer flags are recorded and validated against the replay-supported combination; native token IDs are not captured, so tokenization is not byte-for-byte verified.",
            "Response limits are applied to llama-server stream chunks in the exported native unit; native token boundaries and stop behavior may differ.",
            "Native cache and cold/warm fields are provenance only and are not reproduced by the desktop server process.",
        ],
        "contract_files": contract_files,
        "case_manifest_file": args.case_manifest,
        "case_manifest_sha256": case_manifest_sha256,
        "heldout_fixture_file": args.heldout_fixtures,
        "heldout_fixture_sha256": heldout_fixture_sha256,
        "heldout_case_count": sum(
            1 for result in results if "heldout" in result["score"]
        ),
        "case_count": len(results),
        "passed": evaluation_passed(results),
        "results": results,
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, ensure_ascii=False)
    print("report written to %s" % args.out)

    summarize(results)
    exit_on_evaluation_failure(report["passed"])


if __name__ == "__main__":
    main()
