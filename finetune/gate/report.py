"""Fail-closed G1-G6 verdicts and per-seed evidence for the frozen gate."""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

from . import cxlib
from .build import DEV_VERSION, FROZEN_VERSION, V2_VERSION, HERE, SEEDS, frozen_path, read_jsonl, sha256, text_hash, write_json
from .metrics import (MARGINS, not_worse, paired, preference, preference_pass,
                      template_pairs, yield_pass)
from .generate import SAMPLER
from .judge import judged_counts, make_pairs


def audit_generation(out, role, rows):
    seed_offset = json.loads((out / f"binding-{role}.json").read_text()).get("sampler_seed_offset", 0)
    raw = read_jsonl(out / f"raw-{role}.jsonl")
    latest = {(r["id"], r["seed"], r["pass"]): r for r in raw}
    used = [latest[r["id"], r["seed"], attempt] for r in rows for attempt in range(1, r["calls"] + 1)]
    observed = 0
    for capture in used:
        request = capture["request"]
        if any(request.get(key) != value for key, value in SAMPLER.items()):
            raise ValueError("Capture sampler differs from Android contract")
        if (request["seed"] != capture["seed"] + seed_offset + (capture["pass"] - 1) * 10000
                or capture["sampler_seed"] != request["seed"]):
            raise ValueError("Capture sampler seed differs from frozen seed")
        if len(capture["output"].encode("utf-16-le")) // 2 > 4096:
            raise ValueError("Capture escaped Android's response character budget")
        settings = (capture.get("last_server_payload") or {}).get("generation_settings")
        if settings:
            observed += 1
            for key in ("temperature", "top_k", "top_p", "min_p", "repeat_penalty", "repeat_last_n", "n_predict"):
                if abs(settings[key] - SAMPLER[key]) > 1e-6:
                    raise ValueError(f"Server effective sampler mismatch: {key}")
    write_json(out / f"generation-audit-{role}.json", {"raw_passes": len(raw), "used_passes": len(used),
               "effective_sampler_observations": observed, "termination_counts": dict(Counter(r["termination"] for r in used)),
               "sum_generation_seconds": sum(r["elapsed_ms"] for r in used) / 1000})


def graded(out, prompts, role):
    rows = read_jsonl(out / f"replay-{role}.jsonl")
    expected = {(p, seed) for p in prompts for seed in SEEDS}
    if len(rows) != len(expected) or {(r["id"], r["seed"]) for r in rows} != expected:
        raise ValueError(f"Incomplete/duplicate {role} replay")
    audit_generation(out, role, rows)
    for row in rows:
        if not row["offline_replay_equal"] or row["shown_count"] != len(row["shown_lines"]):
            raise ValueError("Android live/offline replay disagreement")
        prompt = prompts[row["id"]]
        row.update(one=1, passed=int(row["error"] is None), full_six=int(row["error"] is None and row["shown_count"] == 6),
                   retry=int(row["calls"] == 2))
        if row["task"] == "suggestions":
            grades = cxlib.grade_shown_lines(row["shown_lines"], row["level"], prompt["candidate_words"])
            if len(grades) != row["shown_count"]:
                raise ValueError("cxlib silently dropped an Android-shown line")
            row["line_grades"] = grades
            row["level_pass"] = sum(g["pass_level"] for g in grades)
            row["template_matches"], row["line_pairs"] = template_pairs(row["shown_lines"])
    write_json(out / f"graded-{role}.json", rows)
    return {(r["id"], r["seed"]): r for r in rows}


def summarize(rows, judgments, margins=None):
    margins = MARGINS if margins is None else margins
    suggestions = [r for r in rows if r["task"] == "suggestions"]
    metrics = {"full_six": paired(suggestions, "full_six", "one"), "retry": paired(suggestions, "retry", "one"),
               "level_pass": paired(suggestions, "level_pass", "shown_count"),
               "template_repetition": paired(suggestions, "template_matches", "line_pairs")}
    for task in ("rewrite_passage", "rewrite_word", "synonyms"):
        metrics[task] = paired([r for r in rows if r["task"] == task], "passed", "one")
    errors = {role: sum(r[role]["error"] is not None for r in suggestions) for role in ("candidate", "incumbent")}
    groups = {"all": preference(judgments)}
    for axis in ("level", "rhyme_type"):
        for value in sorted({j[axis] for j in judgments if j["task"] == "suggestions"}):
            groups[f"{axis}:{value}"] = preference([j for j in judgments if j["task"] == "suggestions" and j[axis] == value])
    gates = {"G2": yield_pass(metrics, errors["candidate"], margins=margins),
             "G3": preference_pass(groups, len({j["id"] for j in judgments})),
             "G4": not_worse(metrics["level_pass"], margins["level_pass"]),
             "G5": not_worse(metrics["template_repetition"], margins["template_repetition"], False)}
    # Per-seed agreement for G6: point estimates only, since one seed's CIs are too wide to bound.
    net = groups["all"]["net_preference"]
    consistent = {"G2": yield_pass(metrics, errors["candidate"], bound=False, margins=margins),
                  "G3": net is not None and net["delta"] > 0,
                  "G4": not_worse(metrics["level_pass"], margins["level_pass"], bound=False),
                  "G5": not_worse(metrics["template_repetition"], margins["template_repetition"], False, bound=False)}
    return {"gates": gates, "consistent": consistent, "metrics": metrics, "suggestion_errors": errors, "preference": groups,
            "suggestion_categories": {role: dict(Counter(r[role]["category"] for r in suggestions)) for role in errors}}


def gate_verdict(g1, scopes, dev=False):
    """Pooled G2-G5 decide; G6 needs every seed's point estimates to agree. DEV never passes."""
    gates = {"G1": g1, **scopes["pooled"]["gates"], "G6": all(all(scopes[str(s)]["consistent"].values()) for s in SEEDS)}
    return gates, "DEV" if dev else ("PASS" if all(gates.values()) else "FAIL")


def metric_text(metric):
    if metric is None:
        return "undefined (no denominator)"
    lo, hi = metric["ci95"]
    return (f"{100 * metric['candidate']:.2f}% / {100 * metric['incumbent']:.2f}%; "
            f"delta {100 * metric['delta']:+.2f} pp [{100 * lo:+.2f}, {100 * hi:+.2f}]")


def report(out):
    out = Path(out)
    manifest = json.loads((out / "benchmark.json").read_text())
    if manifest["version"] not in (DEV_VERSION, FROZEN_VERSION, V2_VERSION):
        raise ValueError("Unknown evaluation mode")
    dev = manifest["version"] == DEV_VERSION
    frozen = None if dev else json.loads(frozen_path(manifest["version"]).read_text())
    margins = frozen["margins"] if manifest["version"] == V2_VERSION else MARGINS
    bindings = {role: json.loads((out / f"binding-{role}.json").read_text()) for role in ("candidate", "incumbent")}
    seed_pairings = {str(s): {role: s + b.get("sampler_seed_offset", 0) for role, b in bindings.items()} for s in SEEDS}
    prompt_rows = json.loads((out / "prompts.json").read_text())
    prompts = {r["id"]: r for r in prompt_rows}
    results = {role: graded(out, prompts, role) for role in ("candidate", "incumbent")}
    rows = [dict(id=p["id"], song_id=p["song_id"], seed=seed, task=p["task"], level=p["level"], rhyme_type=p["rhyme_type"],
                 **{role: results[role][p["id"], seed] for role in results}) for p in prompt_rows for seed in SEEDS]
    pairs = {p["pair_id"]: p for p in read_jsonl(out / "pairs.jsonl")}
    raw_judgments = read_jsonl(out / "judgments.jsonl")
    if manifest["version"] == V2_VERSION and read_jsonl(out / "pairs.jsonl") != make_pairs(out):
        raise ValueError("V2 judged pairs differ from the frozen selection or captured outputs")
    expected_judgments = len(pairs) if dev else (810 if manifest["version"] == V2_VERSION else 450)
    if len(raw_judgments) != expected_judgments or {j["pair_id"] for j in raw_judgments} != pairs.keys():
        raise ValueError("Missing, extra or duplicate blinded judgments")
    judgments = []
    for judgment in raw_judgments:
        p = pairs[judgment["pair_id"]]
        winner = judgment["winner"]
        outcome = p["left_model" if winner == "L" else "right_model"] if winner in ("L", "R") else winner
        judgments.append(dict(p, outcome=outcome))
    scopes = {"pooled": summarize(rows, judgments, margins)}
    for seed in SEEDS:
        scopes[str(seed)] = summarize([r for r in rows if r["seed"] == seed], [j for j in judgments if j["seed"] == seed], margins)
    parity = read_jsonl(out / "parity.jsonl")
    overlap = json.loads((out / "overlap-final.json").read_text())
    counts = Counter(p["task"] for p in prompt_rows)
    corpus_valid = (not dev and manifest["songs"] == frozen["songs"] and counts == frozen["task_counts"]
                    and manifest["inputs_sha256"] == frozen["inputs_sha256"]
                    and manifest["songs_sha256"] == frozen["songs_sha256"])
    if dev:
        corpus_valid = (manifest["songs"] == len(read_jsonl(out / "benchmark-songs.jsonl"))
                        and counts == manifest["task_counts"] and len(prompts) == manifest["prompts"]
                        and overlap.get("frozen_benchmark_sha256") == sha256(HERE / "benchmark-songs.jsonl"))
    g1 = (corpus_valid
          and len(parity) == (manifest["prompts"] if dev else frozen["prompts"]) and {p["id"] for p in parity} == prompts.keys()
          and all(p["frozen_byte_parity"] and p["prompt_sha256"] == prompts[p["id"]]["prompt_sha256"] for p in parity)
          and overlap["overlapping_lines"] == 0
          and sha256(out / "benchmark-songs.jsonl") == manifest["songs_sha256"]
          and sha256(out / "inputs.json") == manifest["inputs_sha256"]
          and sha256(out / "prompts.json") == (manifest["prompts_sha256"] if dev else frozen["prompts_sha256"])
          and all(text_hash(p["prompt"]) == p["prompt_sha256"] for p in prompt_rows))
    gates, verdict = gate_verdict(g1, scopes, dev)
    judge = json.loads((out / "judge-provenance.json").read_text())
    lines = ["# DEV EVALUATION - not an adoption verdict" if dev else f"# Frozen model gate: {verdict}", "",
             f"Benchmark version: {manifest['version']}.", "",
             "Candidate / incumbent; all differences are candidate minus incumbent.", "",
             "| Gate | Verdict |", "|---|---|"]
    lines.extend(f"| {gate} | {'PASS' if passed else 'FAIL'} |" for gate, passed in gates.items())
    lines.extend(["| G7 | NOT RUN - physical Pixel latency, loading and Stop |", "| G8 | NOT RUN - Tyler blind read |", "",
                  "DEV metrics are informational; no gate result authorizes adoption." if dev else
                  "G3 is mandatory; cxlib cannot rescue a preference failure. G6 requires every seed's point estimates to agree: positive net preference and G2/G4/G5 within their margins.", "",
                  f"Pairing slots and actual first-pass sampler seeds: {seed_pairings}. Retries add 10000 to the corresponding arm's seed.", "",
                  f"G1: {manifest['songs']} {'DEV' if dev else 'new original'} drafts; {counts['suggestions']} suggestions, {counts['rewrite_passage']} passage rewrites, {counts['rewrite_word']} word rewrites, {counts['synonyms']} synonym requests.",
                  f"Kotlin prompt-byte parity: {len(parity)}/{manifest['prompts']}. Overlapping 8-gram lines: {overlap['overlapping_lines']} across {len(overlap['files'])} files"
                  + (f" in {len(overlap['pools'])} training pools." if "pools" in overlap else f"; v4 present: {overlap['v4_present']} (pre-glob audit)."),
                  "See benchmark.json, parity.jsonl, inputs.json, prompts.json and overlap-final.json for hashes and inventory.", "",
                  "95% paired percentile intervals use 20,000 bootstrap resamples of whole songs (seed 20261014), retaining all tasks, prompts, lines and sampler seeds inside each song cluster.",
                  "A [0, 0] null interval contains zero; equality supplies no evidence of a strict improvement.", ""])
    for scope, data in scopes.items():
        lines.extend([f"## {scope}", "", "| Metric | Candidate / incumbent; delta [95% CI] |", "|---|---|"])
        lines.extend(f"| {name} | {metric_text(value)} |" for name, value in data["metrics"].items())
        lines.extend(["", f"Suggestion errors: {data['suggestion_errors']}; categories: {data['suggestion_categories']}.",
                      "Verdicts: " + ", ".join(f"{k}={'PASS' if v else 'FAIL'}" for k, v in data["gates"].items())
                      + "; point-estimate agreement: " + ", ".join(f"{k}={'yes' if v else 'no'}" for k, v in data["consistent"].items()), "",
                      "| Judge scope | Wins / losses / ties | Exact two-sided sign p | Net preference [95% CI] |", "|---|---|---|---|"])
        for key, p in data["preference"].items():
            lines.append(f"| {key} | {p['wins']} / {p['losses']} / {p['ties']} | {p['sign_p']:.6g} | {metric_text(p['net_preference'])} |")
        lines.append("")
    selected_ids = {p["id"] for p in pairs.values()}
    cell_counts = judged_counts([prompts[p] for p in sorted(selected_ids)])
    if dev or manifest["version"] == V2_VERSION:
        lines += ["## Judged prompts per cell (each seed, both positions)", "", "| Cell | Distinct prompts |", "|---|---:|"]
        lines += [f"| {cell} | {count} |" for cell, count in cell_counts.items()]
        lines.append("")
    lines.extend(["## Provenance", "", f"Judge: {judge['model']}; {judge['provider']}; {len(selected_ids)} distinct prompts per seed, both positions.",
                  f"Incremental judge API cost: ${judge['incremental_api_cost_usd']:.2f}. {judge['cost_basis']}. Token usage: {judge['usage']}.",
                  "The template metric counts shown line pairs with identical first three content tokens, divided by all shown line pairs; lower is better.",
                  "This captures desktop llama-server inference through Android Kotlin builders, GenerationBoundary and validators. JNI execution and physical-device performance remain manual G7."])
    for role in results:
        binding = bindings[role]
        lines.extend(["", f"{role}: `{binding['model_path']}`", f"SHA-256: `{binding['model_sha256']}`."])
    (out / "report.md").write_text("\n".join(lines) + "\n")
    write_json(out / "summary.json", {"verdict": verdict, "gates": gates, "scopes": scopes, "judge": judge,
                                      "benchmark_version": manifest["version"], "margins": margins,
                                      "seed_pairings": seed_pairings, "judged_prompt_counts_per_cell": cell_counts,
                                      **({"mode": DEV_VERSION} if dev else {})})
    return verdict
