"""native_contract.py accepts the Android producer's export shape and rejects
drift from the frozen manifest, the record hashes, and the evidence policy.

Run: python3 -B -m unittest discover -s finetune/eval -p 'test_*.py'
"""

import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

FINETUNE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if FINETUNE not in sys.path:
    sys.path.insert(0, FINETUNE)

from eval import native_contract  # noqa: E402

MANIFEST_PATH = os.path.join(FINETUNE, "eval", "native-contract-cases-v1.json")


def _sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _head_sha():
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=native_contract.REPO_ROOT,
        capture_output=True, text=True, check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def android_record(case, manifest, source_sha):
    """The shape NativePromptContractExportTest.contract()/generation() emit,
    after LocalModelInstrumentedTest stamps runtime.evidenceKind=contractExport."""
    user_text = "Android prompt for " + case["caseId"]
    return {
        "schemaVersion": 1,
        "platform": "android",
        "sourceSha": source_sha,
        "modelSha256": manifest["modelSha256"],
        "caseId": case["caseId"],
        "requestKind": case["requestKind"],
        "request": copy.deepcopy(case["request"]),
        "prompt": {
            "userText": user_text,
            "renderedText": user_text,
            "userTextSha256": _sha256(user_text),
            "renderedTextSha256": _sha256(user_text),
            "tokenizerArchitecture": "gemma4",
            "tokenizerEnvelope": "gemma4",
            "tokenizerChatTemplateSha256": "1" * 64,
            "tokenization": {"addSpecial": True, "parseSpecial": True},
        },
        "generation": {
            "engine": {"name": "llama.cpp via vendored kotlinllamacpp", "version": "0.4.0+test"},
            "contextLength": 2048,
            "sampler": {
                "chain": [
                    {"algorithm": "topK", "parameters": {"k": 40}},
                    {"algorithm": "topP", "parameters": {"p": 0.95, "minimumKeep": 1}},
                    {"algorithm": "temperature", "parameters": {"value": 0.7}},
                    {"algorithm": "distribution", "parameters": {}},
                ],
                "seed": {"policy": "engineDefault", "value": -1},
            },
            "termination": {
                "stopOnEog": True,
                "stopSequences": [],
                "maximumOutputTokens": None,
                "maximumResponseLength": 4096,
                "responseLengthUnit": "utf16CodeUnits",
                "deadlineMs": 120000,
                "reason": "notRun",
            },
            "cache": {"clearKvBeforeRequest": False, "promptCache": True, "state": "cold"},
        },
        "runtime": {
            "target": "Android contract export",
            "osVersion": "16",
            "buildVariant": "Debug",
            "evidenceKind": "contractExport",
            "capturedAt": "2026-10-20T12:00:00Z",
        },
    }


def ios_twin(record):
    twin = copy.deepcopy(record)
    twin["platform"] = "ios"
    twin["generation"]["sampler"]["seed"] = {"policy": "randomPerRequest", "value": None}
    twin["generation"]["termination"]["responseLengthUnit"] = "utf8Bytes"
    return twin


class NativeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = native_contract.load_case_manifest(MANIFEST_PATH)
        cls.source_sha = _head_sha() or cls.manifest["baseSourceSha"]
        cls.records = [
            android_record(case, cls.manifest, cls.source_sha) for case in cls.manifest["cases"]
        ]

    def test_android_export_shape_validates_and_round_trips_jsonl(self):
        for record in self.records:
            native_contract.validate_contract(record)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as handle:
            for record in self.records:
                handle.write(json.dumps(record) + "\n")
            path = handle.name
        try:
            loaded = native_contract.load_contracts([path])
            self.assertEqual(
                [row["caseId"] for row in loaded],
                [case["caseId"] for case in self.manifest["cases"]],
            )
            with self.assertRaisesRegex(native_contract.ContractError, "duplicate"):
                native_contract.load_contracts([path, path])
        finally:
            os.unlink(path)

    def test_rejects_record_drift(self):
        failures = [
            ("renderedTextSha256", lambda r: r["prompt"].__setitem__("renderedTextSha256", "0" * 64)),
            ("unknown extra", lambda r: r.__setitem__("extra", True)),
            ("placeholder commit", lambda r: r.__setitem__("sourceSha", "0" * 40)),
            ("placeholder hash", lambda r: r.__setitem__("modelSha256", "0" * 64)),
            ("unsupported exact-replay sampler", lambda r: r["generation"]["sampler"]["chain"].append(
                {"algorithm": "mirostat", "parameters": {}})),
            # NativePromptContractExportTest stamps the pre-runtime stage as
            # contractInput; only the instrumented contractExport is evidence.
            ("unknown evidence kind", lambda r: r["runtime"].__setitem__("evidenceKind", "contractInput")),
            # LocalModelInstrumentedTest's default when nativeContractCapturedAt is absent.
            ("RFC 3339", lambda r: r["runtime"].__setitem__("capturedAt", "not-recorded")),
            ("requires notRun", lambda r: r["generation"]["termination"].__setitem__("reason", "eog")),
        ]
        for pattern, mutate in failures:
            with self.subTest(pattern=pattern):
                record = copy.deepcopy(self.records[0])
                mutate(record)
                with self.assertRaisesRegex(native_contract.ContractError, pattern):
                    native_contract.validate_contract(record)

    def test_manifest_binding(self):
        if _head_sha() is None:
            self.skipTest("git is required to verify source ancestry")
        native_contract.validate_manifest_records(copy.deepcopy(self.records), self.manifest)

        drifted = copy.deepcopy(self.records)
        drifted[0]["request"]["controls"]["drift"] = True
        with self.assertRaisesRegex(native_contract.ContractError, "request"):
            native_contract.validate_manifest_records(drifted, self.manifest)

        drifted = copy.deepcopy(self.records)
        drifted[0]["generation"]["sampler"]["seed"]["value"] = 5
        with self.assertRaisesRegex(native_contract.ContractError, "seed value differs"):
            native_contract.validate_manifest_records(drifted, self.manifest)

        with self.assertRaisesRegex(native_contract.ContractError, "missing"):
            native_contract.validate_manifest_records(copy.deepcopy(self.records[1:]), self.manifest)

        drifted = copy.deepcopy(self.records)
        drifted[0]["sourceSha"] = "f" * 40
        with self.assertRaisesRegex(native_contract.ContractError, "not available"):
            native_contract.validate_manifest_records(drifted, self.manifest)

    def test_platform_pairs_compare_request_not_prompt_bytes(self):
        with self.assertRaisesRegex(native_contract.ContractError, "both ios and android"):
            native_contract.validate_platform_pairs(copy.deepcopy(self.records))
        twins = [ios_twin(record) for record in self.records]
        for twin in twins:
            twin["prompt"]["userText"] = twin["prompt"]["renderedText"] = "iOS wording"
            twin["prompt"]["userTextSha256"] = twin["prompt"]["renderedTextSha256"] = _sha256("iOS wording")
            native_contract.validate_contract(twin)
        native_contract.validate_platform_pairs(copy.deepcopy(self.records) + twins)
        twins[0]["request"]["controls"]["drift"] = True
        with self.assertRaisesRegex(native_contract.ContractError, "disagree on request"):
            native_contract.validate_platform_pairs(copy.deepcopy(self.records) + twins)

    def test_manifest_loader_rejects_drift(self):
        with open(MANIFEST_PATH, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
        mutations = [
            lambda m: m.__setitem__("contractSchema", "other.json"),
            lambda m: m.__setitem__("baseSourceSha", "0" * 40),
            lambda m: m["cases"].append(copy.deepcopy(m["cases"][0])),
            lambda m: m["captureByPlatform"]["android"]["seed"].__setitem__("extra", 1),
        ]
        for index, mutate in enumerate(mutations):
            changed = copy.deepcopy(manifest)
            mutate(changed)
            with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as handle:
                json.dump(changed, handle)
                path = handle.name
            try:
                with self.subTest(mutation=index), self.assertRaises(native_contract.ContractError):
                    native_contract.load_case_manifest(path)
            finally:
                os.unlink(path)

    def test_cli_reports_counts(self):
        if _head_sha() is None:
            self.skipTest("git is required to verify source ancestry")
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as handle:
            for record in self.records:
                handle.write(json.dumps(record) + "\n")
            path = handle.name
        try:
            result = subprocess.run(
                [sys.executable, "-B", os.path.join(FINETUNE, "eval", "native_contract.py"),
                 "--manifest", MANIFEST_PATH, path],
                capture_output=True, text=True, check=True,
            )
        finally:
            os.unlink(path)
        report = json.loads(result.stdout)
        self.assertTrue(report["valid"])
        self.assertEqual(report["recordCount"], len(self.manifest["cases"]))
        self.assertEqual(report["platformCounts"], {"android": len(self.manifest["cases"]), "ios": 0})
        self.assertEqual(report["manifestSha256"], native_contract.model_sha256(MANIFEST_PATH))


if __name__ == "__main__":
    unittest.main()
