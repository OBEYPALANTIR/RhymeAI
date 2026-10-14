"""Independent, blind Codex judge using run_naturalness's rubric and position swap."""
from __future__ import annotations

import hashlib
import json
import random
import select
import subprocess
import time
from pathlib import Path

from eval.run_naturalness import JUDGE_PROMPT, consolidate
from .build import SEEDS, read_jsonl, text_hash, write_json, write_jsonl
from .generate import logic_guard

# This model is available through the existing ChatGPT login; no paid API credential is used.
JUDGE_MODEL = "gpt-6-astra"
SCHEMA = {"type": "object", "additionalProperties": False, "required": ["judgments"], "properties": {
    "judgments": {"type": "array", "items": {"type": "object", "additionalProperties": False,
        "required": ["pair_id", "winner", "reason"], "properties": {"pair_id": {"type": "string"},
            "winner": {"enum": ["L", "R", "tie"]}, "reason": {"type": "string"}}}}}}


def account_usage():
    """Read native billing state without extracting or copying OAuth credentials."""
    process = subprocess.Popen(["codex", "app-server", "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, bufsize=1)
    def request(message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if select.select([process.stdout], [], [], 1)[0]:
                line = process.stdout.readline()
                if not line:
                    raise RuntimeError("Codex billing-state service exited")
                reply = json.loads(line)
                if reply.get("id") == message["id"]:
                    if "error" in reply:
                        raise RuntimeError("Codex billing-state request failed")
                    return reply["result"]
        raise TimeoutError("Codex billing-state request deadline")
    try:
        request({"id": 0, "method": "initialize", "params": {"clientInfo": {"name": "rhymeai-gate-budget", "version": "1.0"}}})
        process.stdin.write('{"method":"initialized"}\n')
        process.stdin.flush()
        result = request({"id": 1, "method": "account/rateLimits/read"})
        limits = result["rateLimits"]
        return {"account_fingerprint": text_hash(result["accountId"]), "ordinary_usage_allowed": result["ordinaryUsageAllowed"],
                "credits": float(limits["credits"]["balance"]), "plan": limits["planType"],
                "used_percent": limits["primary"]["usedPercent"]}
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def selected_prompts(rows):
    groups = {}
    for row in rows:
        if row["task"] == "suggestions":
            groups.setdefault((row["level"], row["rhyme_type"]), []).append(row)
    selected = []
    for key in sorted(groups):
        selected.extend(sorted(groups[key], key=lambda r: text_hash(r["id"]))[:10])
    # 120 suggestions across all 12 cells plus 30 passages (all actions) per seed.
    for action in ("REPHRASE", "HARDER_RHYME", "PUNCH_UP"):
        passages = [r for r in rows if r["task"] == "rewrite_passage" and r["inputs"]["action"] == action]
        selected.extend(sorted(passages, key=lambda r: text_hash(r["id"]))[:10])
    if len(selected) != 150:
        raise ValueError("Judge requires 150 frozen prompt IDs per seed")
    return selected


def make_pairs(out):
    prompts = selected_prompts(json.loads((out / "prompts.json").read_text()))
    results = {role: {(r["id"], r["seed"]): r for r in read_jsonl(out / f"replay-{role}.jsonl")}
               for role in ("candidate", "incumbent")}
    rng = random.Random(3407)
    pairs = []
    for seed in SEEDS:
        for row in prompts:
            left_role, right_role = ("candidate", "incumbent") if rng.random() < .5 else ("incumbent", "candidate")
            pairs.append({"pair_id": text_hash(row["id"] + "#" + str(seed))[:20], "id": row["id"], "seed": seed,
                          "song_id": row["song_id"], "task": row["task"], "level": row["level"], "rhyme_type": row["rhyme_type"],
                          "inner": row["prompt"], "left": "\n".join(results[left_role][row["id"], seed]["shown_lines"]),
                          "right": "\n".join(results[right_role][row["id"], seed]["shown_lines"]),
                          "left_model": left_role, "right_model": right_role})
    rng.shuffle(pairs)
    return pairs


def codex_batch(directory, pairs, swapped, name):
    directory.mkdir(parents=True, exist_ok=True)
    schema = directory / "schema.json"
    write_json(schema, SCHEMA)
    blind = []
    for pair in pairs:
        left, right = (pair["right"], pair["left"]) if swapped else (pair["left"], pair["right"])
        blind.append({"pair_id": pair["pair_id"], "task": JUDGE_PROMPT % (pair["inner"], left, right)})
    prompt = ("Judge each independent pair below. Use only the supplied text and rubric. Do not use tools, "
              "read files, or infer model identities. Return exactly one judgment for every pair_id in the schema.\n"
              + json.dumps(blind, ensure_ascii=False))
    prompt_path = directory / f"{name}.prompt.txt"
    result_path = directory / f"{name}.result.json"
    events_path = directory / f"{name}.events.jsonl"
    exit_path = directory / f"{name}.exit.json"
    binding = {"model": JUDGE_MODEL, "reasoning_effort": "low", "prompt_sha256": text_hash(prompt),
               "subscription_auth": True, "incremental_api_cost_usd": 0.0}
    binding_path = directory / f"{name}.binding.json"
    if binding_path.exists() and json.loads(binding_path.read_text()) != binding:
        raise ValueError("Judge resume binding mismatch")
    if not binding_path.exists():
        if result_path.exists() or events_path.exists():
            raise ValueError("Existing judge captures have no original binding")
        write_json(binding_path, binding)
    if not result_path.exists():
        logic_guard()
        auth = subprocess.run(["codex", "login", "status"], capture_output=True, text=True, timeout=30)
        if auth.returncode or "Logged in using ChatGPT" not in auth.stdout + auth.stderr:
            raise RuntimeError("Gate judge needs existing ChatGPT login; no API fallback is configured")
        before = account_usage()
        if not before["ordinary_usage_allowed"]:
            raise RuntimeError("Included Codex allowance exhausted; paid judge cost must be established within the $25 budget")
        prompt_path.write_text(prompt)
        command = ["codex", "exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check",
                   "-C", str(directory), "-m", JUDGE_MODEL, "-c", 'model_reasoning_effort="low"',
                   "--json", "--output-schema", str(schema), "--output-last-message", str(result_path), "-"]
        write_json(directory / f"{name}.command.json", command)
        write_json(exit_path, {"returncode": None})
        with events_path.open("w") as events, (directory / f"{name}.stderr.log").open("w") as errors:
            proc = subprocess.run(command, input=prompt, text=True, stdout=events, stderr=errors, timeout=600)
        write_json(exit_path, {"returncode": proc.returncode})
        after = account_usage()
        write_json(directory / f"{name}.billing.json", {"before": before, "after": after})
        if proc.returncode:
            raise RuntimeError(f"Independent judge failed; see {events_path} and {directory / (name + '.stderr.log')}")
    if not exit_path.exists() or json.loads(exit_path.read_text()).get("returncode") != 0:
        raise RuntimeError(f"Judge batch has no recorded successful completion: {exit_path}")
    events = read_jsonl(events_path)
    terminal = [e.get("type") for e in events if e.get("type") in ("turn.completed", "turn.failed", "error")]
    if not terminal or terminal[-1] != "turn.completed":
        raise RuntimeError(f"Judge batch has no successful terminal completion: {events_path}")
    billing = json.loads((directory / f"{name}.billing.json").read_text())
    if (billing["before"]["account_fingerprint"] != billing["after"]["account_fingerprint"]
            or billing["before"]["credits"] != billing["after"]["credits"]):
        raise RuntimeError("Judge credit balance/account changed; resolve exact charge and $25 budget before continuing")
    result = json.loads(result_path.read_text())["judgments"]
    if len(result) != len(pairs) or {r["pair_id"] for r in result} != {p["pair_id"] for p in pairs}:
        raise ValueError("Judge did not cover exactly the blinded batch")
    if any(r["winner"] not in ("L", "R", "tie") for r in result):
        raise ValueError("Invalid judge verdict")
    if any(e.get("item", {}).get("type") in ("command_execution", "mcp_tool_call", "web_search") for e in events):
        raise ValueError("Judge used tools; blinding is not certified")
    usage = [e.get("usage", {}) for e in events if e.get("type") == "turn.completed"]
    return result, usage


def judge(out):
    pairs = make_pairs(out)
    write_jsonl(out / "pairs.jsonl", pairs)
    # Workspace outside the run output prevents accidental exposure to answer keys or provenance.
    directory = out.parent / ("blind-judge-" + hashlib.sha256(str(out).encode()).hexdigest()[:12])
    verdicts = [{}, {}]
    usages = []
    for order in (0, 1):
        ordered = list(pairs)
        random.Random(921 + order).shuffle(ordered)
        for offset in range(0, len(ordered), 30):
            name = f"order-{order}-batch-{offset // 30:03d}"
            result, usage = codex_batch(directory, ordered[offset:offset + 30], bool(order), name)
            verdicts[order].update({r["pair_id"]: r for r in result})
            usages.extend(usage)
            print(f"judge {name}: {len(result)} verdicts", flush=True)
    judgments = []
    for pair in pairs:
        first, swapped = [v[pair["pair_id"]] for v in verdicts]
        judgments.append({"pair_id": pair["pair_id"], "winner": consolidate(first["winner"], swapped["winner"]),
                          "orders": [first, swapped], "judge_model": JUDGE_MODEL})
    write_jsonl(out / "judgments.jsonl", judgments)
    write_json(out / "judge-provenance.json", {"model": JUDGE_MODEL, "provider": "OpenAI via Codex ChatGPT login",
               "reasoning_effort": "low", "pairs": len(pairs), "prompt_ids_per_seed": 150, "orders": 2,
               "incremental_api_cost_usd": 0.0, "cost_basis": "Included ChatGPT subscription; unchanged native credit balance around every batch",
               "usage": {key: sum(u.get(key, 0) for u in usages) for key in {k for u in usages for k in u}},
               "blind_workspace": str(directory), "rubric_sha256": text_hash(JUDGE_PROMPT)})
