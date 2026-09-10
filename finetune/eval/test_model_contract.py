from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

from finetune.data import build_adversarial
from finetune.eval import heldout, native_contract, run_eval, scoring


SCHEMA_PATH = "finetune/eval/native-contract-v1.schema.json"
HELDOUT_PATH = "finetune/eval/heldout-cases-v1.json"
TRAINING_PATH = "finetune/data/adversarial-training-cases-v1.json"
MANIFEST_PATH = "finetune/eval/native-contract-cases-v1.json"
HASH_PATH = "finetune/eval/native-contract-v1.sha256"


def _sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def contract(platform, user_text, request=None):
    with open(SCHEMA_PATH, "r", encoding="utf-8") as handle:
        record = copy.deepcopy(json.load(handle)["examples"][0])
    rendered_text = "[%s]\n%s" % (platform, user_text)
    record.update({
        "platform": platform,
        "caseId": "pair_synonyms_glow",
        "request": copy.deepcopy(request) if request is not None else {
            "controls": {"limit": 3},
            "localContext": {"word": "glow", "lineContext": "The lanterns glow"},
        },
    })
    record["prompt"].update({
        "userText": user_text,
        "renderedText": rendered_text,
        "userTextSha256": _sha256(user_text),
        "renderedTextSha256": _sha256(rendered_text),
        "tokenizerChatTemplateSha256": "1" * 64,
    })
    record["generation"]["engine"]["version"] = "test-engine-1"
    record["generation"]["termination"]["responseLengthUnit"] = (
        "utf8Bytes" if platform == "ios" else "utf16CodeUnits"
    )
    return record


class NativeContractTests(unittest.TestCase):
    def test_schema_and_manifest_hashes_match_sidecar(self):
        with open(HASH_PATH, "r", encoding="utf-8") as handle:
            expected = {
                name: digest for digest, name in (
                    line.strip().split(maxsplit=1) for line in handle if line.strip()
                )
            }
        self.assertEqual(expected, {
            "native-contract-v1.schema.json": native_contract.model_sha256(SCHEMA_PATH),
            "native-contract-cases-v1.json": native_contract.model_sha256(MANIFEST_PATH),
        })

    def test_manifest_matches_heldout_requests_and_capture_provenance(self):
        with open(MANIFEST_PATH, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
        fixtures = heldout.load(HELDOUT_PATH)
        manifest_cases = {row["caseId"]: row for row in manifest["cases"]}
        self.assertEqual(len(manifest_cases), len(manifest["cases"]))
        for case_id, fixture in fixtures.items():
            self.assertEqual(manifest_cases[case_id]["requestKind"], fixture["requestKind"])
            self.assertEqual(manifest_cases[case_id]["request"], fixture["request"])
        ios = manifest["captureByPlatform"]["ios"]
        android = manifest["captureByPlatform"]["android"]
        self.assertEqual(ios["evidenceKind"], "contractExport")
        self.assertEqual(ios["seed"]["policy"], "randomPerRequest")
        self.assertFalse(ios["seed"]["recordActualValueInExport"])
        self.assertEqual(android["seed"], {
            "policy": "engineDefault",
            "value": -1,
            "recordActualValueInExport": True,
        })

    def test_schema_example_is_illustrative_only(self):
        with open(SCHEMA_PATH, "r", encoding="utf-8") as handle:
            example = json.load(handle)["examples"][0]
        native_contract.validate_contract(example, exact=False)
        with self.assertRaisesRegex(native_contract.ContractError, "illustrative"):
            native_contract.validate_contract(example, exact=True)

    def test_exact_contract_rejects_placeholder_lineage_hashes(self):
        record = contract("ios", "exact prompt")
        record["sourceSha"] = "0" * 40
        with self.assertRaisesRegex(native_contract.ContractError, "placeholder commit"):
            native_contract.validate_contract(record)
        record = contract("ios", "exact prompt")
        record["modelSha256"] = "0" * 64
        with self.assertRaisesRegex(native_contract.ContractError, "placeholder hash"):
            native_contract.validate_contract(record)

    def test_platform_pair_compares_request_but_allows_native_prompt_differences(self):
        records = [
            contract("ios", "iOS production wording"),
            contract("android", "Android production wording"),
        ]
        native_contract.validate_platform_pairs(records)

        records[1]["request"]["controls"]["limit"] = 4
        with self.assertRaisesRegex(native_contract.ContractError, "request"):
            native_contract.validate_platform_pairs(records)

    def test_loads_native_jsonl_exports(self):
        records = [contract("ios", "iOS prompt"), contract("android", "Android prompt")]
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as handle:
            path = handle.name
            for record in records:
                handle.write(json.dumps(record) + "\n")
        try:
            loaded = native_contract.load_contracts([path])
            self.assertEqual(
                [(row["platform"], row["caseId"]) for row in loaded],
                [(row["platform"], row["caseId"]) for row in records],
            )
        finally:
            os.unlink(path)

    def test_manifest_validation_rejects_semantic_and_seed_drift(self):
        manifest = native_contract.load_case_manifest(MANIFEST_PATH)
        case = manifest["cases"][0]
        record = contract("android", "Android prompt", case["request"])
        record["caseId"] = case["caseId"]
        record["requestKind"] = case["requestKind"]
        record["modelSha256"] = manifest["modelSha256"]
        record["generation"]["sampler"]["seed"] = {
            "policy": "engineDefault", "value": -1
        }
        record["runtime"]["evidenceKind"] = "contractExport"
        with self.assertRaisesRegex(native_contract.ContractError, "missing"):
            native_contract.validate_manifest_records([record], manifest)

        records = []
        for case in manifest["cases"]:
            item = contract("android", "Android prompt for " + case["caseId"], case["request"])
            item["caseId"] = case["caseId"]
            item["requestKind"] = case["requestKind"]
            item["modelSha256"] = manifest["modelSha256"]
            item["generation"]["sampler"]["seed"] = {
                "policy": "engineDefault", "value": -1
            }
            item["runtime"]["evidenceKind"] = "contractExport"
            records.append(item)
        native_contract.validate_manifest_records(records, manifest)
        records[0]["request"]["controls"]["requestedCount"] = 7
        with self.assertRaisesRegex(native_contract.ContractError, "request"):
            native_contract.validate_manifest_records(records, manifest)

    def test_unknown_sampler_is_rejected(self):
        record = contract("ios", "exact prompt")
        record["generation"]["sampler"]["chain"][0] = {
            "algorithm": "mysterySampler", "parameters": {}
        }
        with self.assertRaisesRegex(native_contract.ContractError, "unsupported"):
            native_contract.validate_contract(record)

    def test_unexecuted_random_contract_export_accepts_null_seed(self):
        record = contract("ios", "exported prompt")
        record["generation"]["sampler"]["seed"] = {
            "policy": "randomPerRequest", "value": None
        }
        record["runtime"]["evidenceKind"] = "contractExport"
        native_contract.validate_contract(record)

    def test_manifest_rejects_fabricated_random_export_seed(self):
        manifest = native_contract.load_case_manifest(MANIFEST_PATH)
        records = []
        for case in manifest["cases"]:
            record = contract("ios", "exported prompt for " + case["caseId"], case["request"])
            record["caseId"] = case["caseId"]
            record["requestKind"] = case["requestKind"]
            record["modelSha256"] = manifest["modelSha256"]
            record["generation"]["sampler"]["seed"] = {
                "policy": "randomPerRequest", "value": None
            }
            record["runtime"]["evidenceKind"] = "contractExport"
            records.append(record)
        records[0]["generation"]["sampler"]["seed"]["value"] = 3407
        with self.assertRaisesRegex(native_contract.ContractError, "seed value differs"):
            native_contract.validate_manifest_records(records, manifest)

    def test_native_run_rejects_missing_actual_seed(self):
        record = contract("ios", "native prompt")
        record["generation"]["sampler"]["seed"] = {
            "policy": "randomPerRequest", "value": None
        }
        record["runtime"]["evidenceKind"] = "nativeRun"
        with self.assertRaisesRegex(native_contract.ContractError, "nativeRun requires"):
            native_contract.validate_contract(record)

    def test_runtime_evidence_requires_matching_execution_provenance(self):
        record = contract("android", "native prompt")
        record["runtime"]["evidenceKind"] = "nativeRun"
        record["generation"]["termination"]["reason"] = "eog"
        record["generation"]["sampler"]["seed"] = {
            "policy": "fixed", "value": 3407
        }
        native_contract.validate_contract(record)

        not_run = copy.deepcopy(record)
        not_run["generation"]["termination"]["reason"] = "notRun"
        with self.assertRaisesRegex(native_contract.ContractError, "executed termination"):
            native_contract.validate_contract(not_run)

        unresolved_seed = copy.deepcopy(record)
        unresolved_seed["generation"]["sampler"]["seed"] = {
            "policy": "engineDefault", "value": -1
        }
        with self.assertRaisesRegex(native_contract.ContractError, "resolved non-negative"):
            native_contract.validate_contract(unresolved_seed)

        exported_run = contract("android", "exported prompt")
        exported_run["generation"]["termination"]["reason"] = "eog"
        with self.assertRaisesRegex(native_contract.ContractError, "contractExport requires"):
            native_contract.validate_contract(exported_run)

    def test_capture_timestamp_requires_full_timezone_aware_date_time(self):
        record = contract("ios", "exported prompt")
        for invalid in ("2026-09-09", "2026-09-09T23:00:00"):
            invalid_record = copy.deepcopy(record)
            invalid_record["runtime"]["capturedAt"] = invalid
            with self.assertRaisesRegex(native_contract.ContractError, "with timezone"):
                native_contract.validate_contract(invalid_record)
        record["runtime"]["capturedAt"] = "2026-09-09T23:00:00Z"
        native_contract.validate_contract(record)

    def test_completion_body_uses_separate_controlled_replay_seed(self):
        record = contract("ios", "exact prompt")
        native_seed = copy.deepcopy(record["generation"]["sampler"]["seed"])
        body = native_contract.completion_body(record, replay_seed=991)
        self.assertEqual(body["seed"], 991)
        self.assertEqual(body["min_keep"], 1)
        self.assertEqual(record["generation"]["sampler"]["seed"], native_seed)

    def test_controlled_replay_seed_must_be_deterministic(self):
        record = contract("ios", "exact prompt")
        with self.assertRaisesRegex(native_contract.ContractError, "at least 0"):
            native_contract.completion_body(record, replay_seed=-1)

    def test_response_length_uses_native_units(self):
        self.assertEqual(native_contract.response_length("A😀", "utf8Bytes"), 5)
        self.assertEqual(native_contract.response_length("A😀", "utf16CodeUnits"), 3)

    def test_streaming_replay_preserves_native_chunk_that_crosses_limit(self):
        output, previous, current, reached = run_eval.append_native_chunk(
            "abc", "de", 4, "utf8Bytes"
        )
        self.assertEqual(output, "abcde")
        self.assertEqual(previous, 3)
        self.assertEqual(current, 5)
        self.assertTrue(reached)
        boundary = {
            "enforcedDuringStreaming": True,
            "reached": reached,
            "previousValue": previous,
            "value": current,
        }
        self.assertTrue(run_eval.response_boundary_passed(current, 4, boundary))
        boundary["previousValue"] = 4
        self.assertFalse(run_eval.response_boundary_passed(current, 4, boundary))

    def test_deadline_timeout_is_recorded_for_report(self):
        payload = {"content": "partial"}
        run_eval.record_deadline_timeout(100, payload)
        self.assertEqual(payload["stop_type"], "deadline")
        with self.assertRaises(TimeoutError):
            run_eval.record_deadline_timeout(None, {})
        self.assertTrue(run_eval.is_timeout_error(TimeoutError("timed out")))
        self.assertTrue(
            run_eval.is_timeout_error(run_eval.urllib.error.URLError(TimeoutError("timed out")))
        )
        self.assertFalse(run_eval.is_timeout_error(run_eval.urllib.error.URLError(OSError("down"))))

    def test_case_limit_must_be_positive(self):
        self.assertEqual(run_eval.positive_integer_argument("2"), 2)
        for invalid in ("0", "-1", "not-a-number"):
            with self.assertRaises(argparse.ArgumentTypeError):
                run_eval.positive_integer_argument(invalid)

    def test_contract_file_evidence_hashes_input_bytes(self):
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
            handle.write("native-contract-bytes")
            handle.flush()
            self.assertEqual(run_eval.contract_file_evidence([handle.name]), [{
                "path": handle.name,
                "sha256": hashlib.sha256(b"native-contract-bytes").hexdigest(),
            }])

    def test_targeted_rhyme_miss_fails_case(self):
        score = {
            "format": {"passed": True},
            "response_length": {"passed": True},
            "rhyme": {"per_line": [{}], "miss": 1},
        }
        self.assertFalse(run_eval.score_passed(score))
        score["rhyme"]["miss"] = 0
        self.assertTrue(run_eval.score_passed(score))
        score["termination"] = {"passed": False, "reason": "deadline"}
        self.assertFalse(run_eval.score_passed(score))

    def test_evaluation_gate_fails_when_any_case_fails(self):
        self.assertTrue(run_eval.evaluation_passed([{"passed": True}]))
        self.assertFalse(run_eval.evaluation_passed([{"passed": True}, {"passed": False}]))
        self.assertFalse(run_eval.evaluation_passed([]))
        run_eval.exit_on_evaluation_failure(True)
        with self.assertRaises(SystemExit) as failure:
            run_eval.exit_on_evaluation_failure(False)
        self.assertEqual(failure.exception.code, 1)


class LexicalFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.heldout = heldout.load(HELDOUT_PATH)
        cls.training = build_adversarial.load_specs(TRAINING_PATH)

    def test_separator_adversaries_fail_spelling_and_rejection(self):
        glow = scoring.validate_single_word_rewrite("g-l-e-a-m", "glow", ["gleam"])
        crooked = scoring.validate_single_word_rewrite("a-skew", "crooked", ["askew"])
        for result in (glow, crooked):
            self.assertIn("invalid_lexical_spelling", result["violations"])
            self.assertIn("in_rejected_list", result["violations"])

    def test_all_declared_adversarial_violations_are_observed(self):
        for fixture in self.heldout.values():
            for adversary in fixture["evaluation"]["adversarialOutputs"]:
                observed = heldout.adversarial_violations(fixture, adversary["text"])
                for violation in adversary["violations"]:
                    self.assertTrue(
                        observed[violation],
                        "%s did not observe %s for %r" % (
                            fixture["caseId"], violation, adversary["text"]
                        ),
                    )

    def test_training_and_heldout_requests_are_disjoint(self):
        build_adversarial.validate_disjoint(self.training, self.heldout)
        for row in self.heldout.values():
            self.assertNotIn("trainingCompletion", row["evaluation"])

    def test_adversarial_training_completions_pass_boundary_scoring(self):
        for spec in self.training.values():
            build_adversarial.validate_completion(spec)

    def test_adversarial_builder_creates_missing_output_directory(self):
        records = []
        for spec in self.training.values():
            for platform in native_contract.PLATFORMS:
                record = contract(platform, "native prompt for " + spec["caseId"], spec["request"])
                record["caseId"] = spec["caseId"]
                record["requestKind"] = spec["requestKind"]
                records.append(record)

        with tempfile.TemporaryDirectory() as directory:
            contracts_path = os.path.join(directory, "contracts.jsonl")
            output_path = os.path.join(directory, "missing", "adversarial-v1.jsonl")
            with open(contracts_path, "w", encoding="utf-8") as handle:
                for record in records:
                    handle.write(json.dumps(record) + "\n")
            subprocess.run(
                [
                    sys.executable,
                    "finetune/data/build_adversarial.py",
                    "--contracts",
                    contracts_path,
                    "--out",
                    output_path,
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            with open(output_path, "r", encoding="utf-8") as handle:
                self.assertEqual(len(handle.readlines()), len(records))

    def test_raw_markers_are_rejected_before_cleanup(self):
        for marker in ("<start_of_turn>model\n", "<|turn>model\n", "<turn|>\n"):
            result = scoring.validate_single_word_rewrite(marker + "shine", "glow", [])
            self.assertIn("control_marker", result["violations"])


if __name__ == "__main__":
    unittest.main()
