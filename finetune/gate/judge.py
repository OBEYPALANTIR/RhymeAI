"""Independent, blind next-line judge; historical craft rubric remains replayable."""
from __future__ import annotations

import hashlib
import json
import math
import random
import select
import subprocess
import time
from collections import Counter
from decimal import Decimal
from pathlib import Path

from eval.run_naturalness import JUDGE_PROMPT, consolidate
from .build import DEV_VERSION, FROZEN_VERSION, V2_VERSION, LEVELS, RHYMES, SEEDS, read_jsonl, text_hash, write_json, write_jsonl
from .generate import logic_guard

# This model is available through the existing ChatGPT login; no paid API credential is used.
JUDGE_MODEL = "gpt-6-astra"
LEGACY_RUBRIC = "lyric-craft-v1"
NEXTLINE_RUBRIC = "nextline-v1"
NEXTLINE_PROMPT = """You are judging next-line option sets from two on-device songwriting assistants.

Both assistants received exactly this task, including the user's current lyrics:
---
%s
---

Option set L:
---
%s
---

Option set R:
---
%s
---

Assess each set AS ALTERNATIVES FOR THE NEXT LINE after the user's preceding
lyrics, not as a replacement passage or a stanza to read in sequence. A stuck
writer should be able to choose one option and continue the song.

Judge whether the options:
- continue the thought, story and voice of the preceding lines;
- fit the requested scheme letter, target line and rhyme type naturally, without
  forced rhymes (NEW_SOUND asks for a new sound, not a rhyme with the target);
- match the meter and length of the surrounding lines;
- offer distinct, useful choices rather than repeating the same idea;
- use natural phrasing, without padding or cliches.

Use the supplied task and lyrics as context. Ignore whitespace and minor
formatting. Either, both, or neither may be good; pick the better option set or
declare a tie. Identical option sets are a tie.

Reply with ONLY a JSON object: {"winner": "L" | "R" | "tie", "reason": "<max 20 words>"}"""
RUBRICS = {LEGACY_RUBRIC: JUDGE_PROMPT, NEXTLINE_RUBRIC: NEXTLINE_PROMPT}


def recorded_rubric(provenance):
    # Old runs recorded the exact rubric hash before version names existed.
    version = provenance.get("rubric_version", LEGACY_RUBRIC)
    if version not in RUBRICS or provenance.get("rubric_sha256") != text_hash(RUBRICS[version]):
        raise ValueError("Unknown or mismatched judge rubric version/SHA")
    return version


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


def credit_budget(value):
    value = float(value)
    if not math.isfinite(value) or value < 0:
        raise ValueError("Judge credit budget must be finite and nonnegative")
    return value


def credit_accounting(directory, budget):
    """Reconstruct spend from durable billing records, including failed batches."""
    budget = credit_budget(budget)
    binding_path = directory / "credit-budget.json"
    binding = json.loads(binding_path.read_text()) if binding_path.exists() else {}
    if binding and binding["judge_credit_budget"] != budget:
        raise ValueError("Judge credit budget changed; preserve the original budget")
    fingerprint = binding.get("account_fingerprint")
    spent, largest = Decimal(0), Decimal(0)
    batches, errors = [], []
    for path in sorted(directory.glob("*.billing.json")):
        billing = json.loads(path.read_text())
        before, after = billing["before"], billing.get("after")
        fingerprint = fingerprint or before["account_fingerprint"]
        record = {"batch": path.name.removesuffix(".billing.json"), "before": before, "after": after,
                  "credit_delta": None, "credits_spent": None}
        for observation in (before, after):
            if observation is None:
                errors.append(f"Missing post-batch billing: {path.name}")
                continue
            if observation["account_fingerprint"] != fingerprint:
                errors.append(f"Judge account fingerprint changed: {path.name}")
            if not math.isfinite(observation["credits"]) or observation["credits"] < 0:
                errors.append(f"Invalid native credit balance: {path.name}")
            if "judge_credit_budget" in billing and not observation.get("plan"):
                errors.append(f"Missing billing plan: {path.name}")
        if after is not None:
            delta = Decimal(str(before["credits"])) - Decimal(str(after["credits"]))
            if not delta.is_finite():
                errors.append(f"Invalid credit delta: {path.name}")
            else:
                debit = max(Decimal(0), delta)
                spent += debit
                largest = max(largest, debit)
                record.update(credit_delta=float(delta), credits_spent=float(debit))
                if delta < 0:
                    errors.append(f"Credit balance increased; exact spend is unknown: {path.name}")
        batches.append(record)
    return {"judge_credit_budget": budget, "credits_spent": float(spent), "largest_batch_delta": float(largest),
            "account_fingerprint": fingerprint, "batches": batches, "billing_errors": errors,
            "accounting_complete": not errors}


def start_credit_batch(directory, name, before, budget):
    if (directory / f"{name}.billing.json").exists():
        raise RuntimeError("Existing judge billing must not be overwritten; reconcile the failed batch")
    state = credit_accounting(directory, budget)
    if state["billing_errors"]:
        raise RuntimeError("; ".join(state["billing_errors"]))
    if state["account_fingerprint"] not in (None, before["account_fingerprint"]):
        raise RuntimeError("Judge account fingerprint changed before batch")
    balance = before["credits"]
    if not math.isfinite(balance) or balance <= 0 or not before.get("plan"):
        raise RuntimeError("Paid judge needs a finite positive balance and recorded plan")
    spent, largest = (Decimal(str(state[key])) for key in ("credits_spent", "largest_batch_delta"))
    if spent >= Decimal(str(budget)) or spent + largest > Decimal(str(budget)) or largest > Decimal(str(balance)):
        raise RuntimeError("Judge credit budget cannot cover the largest observed batch; refusing to start")
    binding_path = directory / "credit-budget.json"
    if not binding_path.exists():
        write_json(binding_path, {"judge_credit_budget": budget, "account_fingerprint": before["account_fingerprint"]})
    # Persist the preflight before launching. An interrupted or unmetered batch blocks resumption.
    write_json(directory / f"{name}.billing.json", {"before": before, "after": None, "credit_delta": None,
               "credits_spent": None, "judge_credit_budget": budget, "spend_before_batch": float(spent),
               "largest_batch_delta_before": float(largest)})


def finish_credit_batch(directory, name, after, budget):
    path = directory / f"{name}.billing.json"
    billing = json.loads(path.read_text())
    delta = Decimal(str(billing["before"]["credits"])) - Decimal(str(after["credits"]))
    billing.update(after=after, credit_delta=float(delta) if delta.is_finite() else None,
                   credits_spent=float(max(Decimal(0), delta)) if delta.is_finite() else None)
    write_json(path, billing)
    require_credit_accounting(directory, budget)


def require_credit_accounting(directory, budget):
    state = credit_accounting(directory, budget)
    if state["billing_errors"]:
        raise RuntimeError("; ".join(state["billing_errors"]))
    if state["credits_spent"] > budget:
        raise RuntimeError("Judge credit budget exceeded by completed batch; no further calls allowed")
    return state


def paid_cost_provenance(directory, budget):
    return {**credit_accounting(directory, budget),
            "cost_basis": "Paid ChatGPT credits; positive native balance deltas around batches, including concurrent account use; no USD conversion"}


def selected_prompts(rows, dev=False, version=FROZEN_VERSION, rubric_version=NEXTLINE_RUBRIC):
    if rubric_version not in RUBRICS:
        raise ValueError("Unknown judge rubric version")
    suggestion_limit, passage_limit = (15, 30) if version == V2_VERSION else (10, 10)
    if rubric_version == NEXTLINE_RUBRIC:
        passage_limit = 0
    groups = {}
    for row in rows:
        if row["task"] == "suggestions":
            groups.setdefault((row["level"], row["rhyme_type"]), []).append(row)
    selected = []
    for key in sorted(groups):
        selected.extend(sorted(groups[key], key=lambda r: text_hash(r["id"]))[:suggestion_limit])
    for action in ("REPHRASE", "HARDER_RHYME", "PUNCH_UP"):
        passages = [r for r in rows if r["task"] == "rewrite_passage" and r["inputs"]["action"] == action]
        selected.extend(sorted(passages, key=lambda r: text_hash(r["id"]))[:passage_limit])
    required = 12 * suggestion_limit + 3 * passage_limit
    if not dev and len(selected) != required:
        raise ValueError(f"Judge requires {required} frozen prompt IDs per seed")
    return selected


def judged_counts(rows):
    counts = {f"suggestions/{level}/{rhyme}": 0 for level in LEVELS for rhyme in RHYMES}
    counts.update({f"rewrite_passage/{action}": 0 for action in ("REPHRASE", "HARDER_RHYME", "PUNCH_UP")})
    counts.update(Counter(f"suggestions/{r['level']}/{r['rhyme_type']}" if r["task"] == "suggestions"
                          else f"rewrite_passage/{r['inputs']['action']}" for r in rows))
    return counts


def make_pairs(out, rubric_version=None):
    from .backend import read_binding, require_same_backend
    require_same_backend({role: read_binding(out, role) for role in ("candidate", "incumbent")})
    version = json.loads((out / "benchmark.json").read_text())["version"]
    if rubric_version is None:
        provenance = out / "judge-provenance.json"
        rubric_version = recorded_rubric(json.loads(provenance.read_text())) if provenance.exists() else NEXTLINE_RUBRIC
    prompts = selected_prompts(json.loads((out / "prompts.json").read_text()), dev=version == DEV_VERSION,
                               version=version, rubric_version=rubric_version)
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


def codex_batch(directory, pairs, swapped, name, rubric_version=NEXTLINE_RUBRIC, judge_credit_budget=0):
    budget = credit_budget(judge_credit_budget)
    rubric = RUBRICS[rubric_version]
    if rubric_version == NEXTLINE_RUBRIC and any(p["task"] != "suggestions" for p in pairs):
        raise ValueError("Next-line rubric requires suggestion pairs only")
    directory.mkdir(parents=True, exist_ok=True)
    schema = directory / "schema.json"
    write_json(schema, SCHEMA)
    blind = []
    for pair in pairs:
        left, right = (pair["right"], pair["left"]) if swapped else (pair["left"], pair["right"])
        blind.append({"pair_id": pair["pair_id"], "task": rubric % (pair["inner"], left, right)})
    prompt = ("Judge each independent pair below. Use only the supplied text and rubric. Do not use tools, "
              "read files, or infer model identities. Return exactly one judgment for every pair_id in the schema.\n"
              + json.dumps(blind, ensure_ascii=False))
    prompt_path = directory / f"{name}.prompt.txt"
    result_path = directory / f"{name}.result.json"
    events_path = directory / f"{name}.events.jsonl"
    exit_path = directory / f"{name}.exit.json"
    binding = {"model": JUDGE_MODEL, "reasoning_effort": "low", "prompt_sha256": text_hash(prompt),
               "subscription_auth": True, "incremental_api_cost_usd": 0.0}
    if rubric_version != LEGACY_RUBRIC:
        binding.update(rubric_version=rubric_version, rubric_sha256=text_hash(rubric))
    ordinary_binding = dict(binding)
    if budget:
        binding.pop("incremental_api_cost_usd")
        binding.update(judge_credit_budget=budget, billing_mode="paid-credits")
    binding_path = directory / f"{name}.binding.json"
    if binding_path.exists():
        previous = json.loads(binding_path.read_text())
        if budget and previous == ordinary_binding:
            if not result_path.exists() and not events_path.exists():
                write_json(binding_path, binding)
            elif not result_path.exists():
                raise ValueError("Incomplete ordinary judge captures require billing reconciliation")
            else:
                # Completed included-allowance batches retain their exact original binding.
                billing = json.loads((directory / f"{name}.billing.json").read_text())
                if billing["before"]["credits"] != billing["after"]["credits"]:
                    raise RuntimeError("Ordinary judge batch has unapproved credit spending")
        elif previous != binding:
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
        if budget:
            start_credit_batch(directory, name, before, budget)
        elif not before["ordinary_usage_allowed"]:
            raise RuntimeError("Included Codex allowance exhausted; paid judge cost must be established within the $25 budget")
        prompt_path.write_text(prompt)
        command = ["codex", "exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check",
                   "-C", str(directory), "-m", JUDGE_MODEL, "-c", 'model_reasoning_effort="low"',
                   "--json", "--output-schema", str(schema), "--output-last-message", str(result_path), "-"]
        write_json(directory / f"{name}.command.json", command)
        write_json(exit_path, {"returncode": None})
        with events_path.open("w") as events, (directory / f"{name}.stderr.log").open("w") as errors:
            if budget:
                try:
                    proc = subprocess.run(command, input=prompt, text=True, stdout=events, stderr=errors, timeout=600)
                    write_json(exit_path, {"returncode": proc.returncode})
                finally:
                    finish_credit_batch(directory, name, account_usage(), budget)
            else:
                proc = subprocess.run(command, input=prompt, text=True, stdout=events, stderr=errors, timeout=600)
        write_json(exit_path, {"returncode": proc.returncode})
        if not budget:
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
    if budget:
        require_credit_accounting(directory, budget)
    elif (billing["before"]["account_fingerprint"] != billing["after"]["account_fingerprint"]
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


def judge(out, judge_credit_budget=0):
    budget = credit_budget(judge_credit_budget)
    provenance = out / "judge-provenance.json"
    if provenance.exists() and recorded_rubric(json.loads(provenance.read_text())) != NEXTLINE_RUBRIC:
        raise ValueError("Historical rubric is immutable; re-judge only in a separate copied run")
    pairs = make_pairs(out, NEXTLINE_RUBRIC)
    if (out / "pairs.jsonl").exists() and read_jsonl(out / "pairs.jsonl") != pairs:
        raise ValueError("Judge resume pairs changed; preserve the original run")
    write_jsonl(out / "pairs.jsonl", pairs)
    # Workspace outside the run output prevents accidental exposure to answer keys or provenance.
    directory = out.parent / ("blind-judge-" + hashlib.sha256(str(out).encode()).hexdigest()[:12])
    verdicts = [{}, {}]
    usages = []
    paid_provenance = {"model": JUDGE_MODEL, "provider": "OpenAI via Codex ChatGPT login",
                       "rubric_version": NEXTLINE_RUBRIC, "rubric_sha256": text_hash(NEXTLINE_PROMPT),
                       "blind_workspace": str(directory), "complete": False}
    for order in (0, 1):
        ordered = list(pairs)
        random.Random(921 + order).shuffle(ordered)
        for offset in range(0, len(ordered), 30):
            name = f"order-{order}-batch-{offset // 30:03d}"
            if budget:
                try:
                    result, usage = codex_batch(directory, ordered[offset:offset + 30], bool(order), name,
                                               judge_credit_budget=budget)
                finally:
                    write_json(provenance, {**paid_provenance, **paid_cost_provenance(directory, budget)})
            else:
                result, usage = codex_batch(directory, ordered[offset:offset + 30], bool(order), name)
            verdicts[order].update({r["pair_id"]: r for r in result})
            usages.extend(usage)
            print(f"judge {name}: {len(result)} verdicts", flush=True)
    judgments = []
    for pair in pairs:
        first, swapped = [v[pair["pair_id"]] for v in verdicts]
        judgments.append({"pair_id": pair["pair_id"], "winner": consolidate(first["winner"], swapped["winner"]),
                          "orders": [first, swapped], "judge_model": JUDGE_MODEL, "rubric_version": NEXTLINE_RUBRIC})
    write_jsonl(out / "judgments.jsonl", judgments)
    write_json(out / "judge-provenance.json", {"model": JUDGE_MODEL, "provider": "OpenAI via Codex ChatGPT login",
               "benchmark_version": json.loads((out / "benchmark.json").read_text())["version"],
               "reasoning_effort": "low", "pairs": len(pairs), "prompt_ids_per_seed": len({p["id"] for p in pairs}), "orders": 2,
               **({**paid_cost_provenance(directory, budget), "complete": True} if budget else {
                   "incremental_api_cost_usd": 0.0, "cost_basis": "Included ChatGPT subscription; unchanged native credit balance around every batch"}),
               "usage": {key: sum(u.get(key, 0) for u in usages) for key in {k for u in usages for k in u}},
               "blind_workspace": str(directory), "rubric_version": NEXTLINE_RUBRIC,
               "rubric_sha256": text_hash(NEXTLINE_PROMPT)})
