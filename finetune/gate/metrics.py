"""Paired uncertainty and mechanical diversity; no model-dependent thresholds."""
from __future__ import annotations

import re
from collections import defaultdict

import numpy as np
from eval.run_naturalness import sign_test_p

BOOTSTRAPS = 20000
BOOTSTRAP_SEED = 20261014
FUNCTION_WORDS = frozenset("a an the i me my mine we us our ours you your yours he him his she her hers it its they them their theirs and or but if as at by for from in into of on onto to with is am are was were be been being do does did have has had this that these those".split())


def template_pairs(lines):
    """Count pairs sharing their first three content tokens; denominator is all shown pairs."""
    prefixes = []
    for line in lines:
        tokens = [word for word in re.findall(r"[a-z]+(?:'[a-z]+)?", line.lower()) if word not in FUNCTION_WORDS]
        prefixes.append(tuple(tokens[:3]) if len(tokens) >= 3 else None)
    count = sum(a is not None and a == b for i, a in enumerate(prefixes) for b in prefixes[i + 1:])
    return count, len(lines) * (len(lines) - 1) // 2


def paired(rows, numerator, denominator):
    """Promoted ratio bootstrap, clustered by song to preserve repeated prompts and seeds."""
    clusters = defaultdict(lambda: np.zeros(4))
    for row in rows:
        clusters[row["song_id"]] += [row["candidate"][numerator], row["candidate"][denominator],
                                    row["incumbent"][numerator], row["incumbent"][denominator]]
    if not clusters:
        return None
    data = np.array(list(clusters.values()), dtype=float)
    total = data.sum(axis=0)
    if not total[1] or not total[3]:
        return None
    samples = data[np.random.default_rng(BOOTSTRAP_SEED).integers(0, len(data), (BOOTSTRAPS, len(data)))].sum(axis=1)
    valid = (samples[:, 1] > 0) & (samples[:, 3] > 0)
    deltas = samples[valid, 0] / samples[valid, 1] - samples[valid, 2] / samples[valid, 3]
    return {"candidate": float(total[0] / total[1]), "incumbent": float(total[2] / total[3]),
            "delta": float(total[0] / total[1] - total[2] / total[3]), "ci95": np.quantile(deltas, [.025, .975]).tolist(),
            "candidate_counts": total[:2].astype(int).tolist(), "incumbent_counts": total[2:].astype(int).tolist(),
            "song_clusters": len(data), "paired_requests": len(rows), "bootstrap_valid": int(valid.sum())}


def preference(rows):
    wins = sum(r["outcome"] == "candidate" for r in rows)
    losses = sum(r["outcome"] == "incumbent" for r in rows)
    ties = sum(r["outcome"] == "tie" for r in rows)
    result = {"n": len(rows), "wins": wins, "losses": losses, "ties": ties,
              "invalid": len(rows) - wins - losses - ties, "sign_p": sign_test_p(wins, losses)}
    # Judgments repeat prompts (3 seeds) and songs (several prompts each), so rows are not
    # independent: the verdict uses the song-cluster bootstrap; sign_p stays descriptive.
    paired_rows = [{"song_id": r["song_id"], "candidate": {"win": int(r["outcome"] == "candidate"), "one": 1},
                    "incumbent": {"win": int(r["outcome"] == "incumbent"), "one": 1}} for r in rows]
    result["net_preference"] = paired(paired_rows, "win", "one")
    return result


# Non-inferiority margins (heuristic): 2 x the disjoint-seed null's pooled 95% CI half-width (shipped
# v2.1 against itself), rounded up to 0.5 pp with a 1 pp floor, except repetition: 0.05 pp, no floor. Not a validated
# null-pass rate; see GATE.md "Calibration". bound=False checks point estimates (G6).
FULL_SIX_MARGIN, RETRY_MARGIN, LEVEL_MARGIN, REPETITION_MARGIN = .01, .065, .055, .0025
REWRITE_MARGINS = {"rewrite_passage": .085, "rewrite_word": .035, "synonyms": .01}
MARGINS = {"full_six": FULL_SIX_MARGIN, "retry": RETRY_MARGIN, "level_pass": LEVEL_MARGIN,
           "template_repetition": REPETITION_MARGIN, **REWRITE_MARGINS}


def _lower(metric, bound):
    return metric["ci95"][0] if bound else metric["delta"]


def _upper(metric, bound):
    return metric["ci95"][1] if bound else metric["delta"]


def yield_pass(metrics, candidate_errors, bound=True, margins=None):
    margins = MARGINS if margins is None else margins
    required = [metrics.get(key) for key in ("full_six", "retry", "rewrite_passage", "rewrite_word", "synonyms")]
    return (all(m is not None for m in required) and candidate_errors == 0
            and _lower(metrics["full_six"], bound) >= -margins["full_six"] - 1e-12
            and _upper(metrics["retry"], bound) <= margins["retry"] + 1e-12
            and all(_lower(metrics[k], bound) >= -margins[k] - 1e-12 for k in REWRITE_MARGINS))


def preference_pass(groups, distinct_prompts):
    overall = groups["all"]
    net = overall["net_preference"]
    return (distinct_prompts >= 150 and overall["invalid"] == 0 and net is not None and net["ci95"][0] > 0
            and not any(g["net_preference"] is not None and g["net_preference"]["ci95"][1] < 0
                        for key, g in groups.items() if key != "all"))


def not_worse(metric, margin, higher_is_better=True, bound=True):
    if metric is None:
        return False
    return (_lower(metric, bound) >= -margin - 1e-12 if higher_is_better
            else _upper(metric, bound) <= margin + 1e-12)
