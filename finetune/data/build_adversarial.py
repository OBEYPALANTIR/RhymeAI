#!/usr/bin/env python3
"""Build training JSONL from exact native exports for disjoint adversarial cases."""

from __future__ import annotations

import argparse
import json
import os
import sys

_FINETUNE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _FINETUNE_DIR not in sys.path:
    sys.path.insert(0, _FINETUNE_DIR)

from eval import heldout, native_contract, scoring  # noqa: E402


def load_specs(path):
    with open(path, "r", encoding="utf-8") as handle:
        rows = json.load(handle)
    if not isinstance(rows, list) or not rows:
        raise ValueError("adversarial training fixture must be a non-empty JSON array")
    ids = [row["caseId"] for row in rows]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate adversarial training caseId")
    return {row["caseId"]: row for row in rows}


def validate_disjoint(training_specs, heldout_fixtures):
    overlapping_ids = set(training_specs) & set(heldout_fixtures)
    if overlapping_ids:
        raise ValueError("training and held-out caseIds overlap: %s" % sorted(overlapping_ids))
    heldout_requests = {
        json.dumps(row["request"], sort_keys=True, ensure_ascii=False)
        for row in heldout_fixtures.values()
    }
    duplicate_requests = [
        case_id for case_id, row in training_specs.items()
        if json.dumps(row["request"], sort_keys=True, ensure_ascii=False) in heldout_requests
    ]
    if duplicate_requests:
        raise ValueError("training and held-out semantic requests overlap: %s" % duplicate_requests)

    def fixture_vocabulary(rows, *, training):
        words = set()
        for row in rows.values():
            context = row["request"]["localContext"]
            controls = row["request"]["controls"]
            for key in ("word", "selection"):
                if context.get(key):
                    words.add(scoring.rejection_key(context[key]))
            for word in controls.get("rejectedCandidates", []):
                words.add(scoring.rejection_key(word))
            if training:
                values = row["completion"].splitlines() + row["adversarialRejectedOutputs"]
            else:
                evaluation = row["evaluation"]
                values = evaluation["acceptedSpellings"] + evaluation["rejectedSpellings"]
                values += [item["text"] for item in evaluation["adversarialOutputs"]]
            words.update(scoring.rejection_key(word) for word in values)
        return {word for word in words if word}

    overlap = fixture_vocabulary(training_specs, training=True) & fixture_vocabulary(
        heldout_fixtures, training=False
    )
    if overlap:
        raise ValueError("training and held-out lexical targets overlap: %s" % sorted(overlap))


def validate_completion(spec):
    request = spec["request"]
    if spec["requestKind"] == "rewrite_word":
        result = scoring.validate_single_word_rewrite(
            spec["completion"],
            request["localContext"]["selection"],
            request["controls"]["rejectedCandidates"],
        )
    elif spec["requestKind"] == "synonyms":
        result = scoring.validate_synonyms(
            spec["completion"],
            request["localContext"]["word"],
            request["controls"]["limit"],
        )
    else:
        raise ValueError("unsupported adversarial task %s" % spec["requestKind"])
    if not result["passed"]:
        raise ValueError("%s completion fails scoring: %s" % (spec["caseId"], result))


def build_rows(contracts, training_specs, heldout_fixtures, base_source_sha):
    validate_disjoint(training_specs, heldout_fixtures)
    selected = [record for record in contracts if record["caseId"] in training_specs]
    replay_records = [
        "%s/%s" % (record["platform"], record["caseId"])
        for record in selected
        if record["runtime"]["evidenceKind"] not in {"contractExport", "nativeRun"}
    ]
    if replay_records:
        raise ValueError(
            "adversarial training requires native prompt lineage; controlled replay records: %s"
            % replay_records
        )
    native_contract.validate_source_ancestry(selected, base_source_sha)
    native_contract.validate_platform_pairs(selected)
    expected_pairs = {
        (platform, case_id)
        for platform in native_contract.PLATFORMS
        for case_id in training_specs
    }
    actual_pairs = {(record["platform"], record["caseId"]) for record in selected}
    missing = sorted(expected_pairs - actual_pairs)
    if missing:
        raise ValueError("native adversarial exports missing %s" % missing)

    rows = []
    for record in selected:
        spec = training_specs[record["caseId"]]
        if record["requestKind"] != spec["requestKind"] or record["request"] != spec["request"]:
            raise ValueError("%s: native request differs from training fixture" % spec["caseId"])
        validate_completion(spec)
        rows.append({
            "task": record["requestKind"],
            "case_seed": "%s-%s" % (record["caseId"], record["platform"]),
            "case_params": {
                "caseId": record["caseId"],
                "platform": record["platform"],
                "request": record["request"],
                "sourceSha": record["sourceSha"],
                "modelSha256": record["modelSha256"],
                "userTextSha256": record["prompt"]["userTextSha256"],
            },
            "user_prompt": record["prompt"]["userText"],
            "completion": spec["completion"],
        })
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--contracts", nargs="+", required=True)
    parser.add_argument(
        "--cases",
        default=os.path.join(os.path.dirname(__file__), "adversarial-training-cases-v1.json"),
    )
    parser.add_argument(
        "--heldout",
        default=os.path.join(os.path.dirname(__file__), "..", "eval", "heldout-cases-v1.json"),
    )
    parser.add_argument(
        "--manifest",
        default=os.path.join(os.path.dirname(__file__), "..", "eval", "native-contract-cases-v1.json"),
    )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    contracts = native_contract.load_contracts(args.contracts, exact=True)
    manifest = native_contract.load_case_manifest(args.manifest)
    rows = build_rows(
        contracts,
        load_specs(args.cases),
        heldout.load(args.heldout),
        manifest["baseSourceSha"],
    )
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    print("wrote %s (%d rows)" % (args.out, len(rows)))


if __name__ == "__main__":
    main()
