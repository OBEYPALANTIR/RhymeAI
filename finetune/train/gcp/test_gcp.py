"""Small boundary checks; cloud lifecycle and GPU behavior require the real smoke run."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gcp_run", HERE / "run.py")
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)


class PackageTests(unittest.TestCase):
    def test_capacity_order_keeps_l4_after_all_a100_zones(self):
        inventory = [{"name": name, "zone": "zones/" + zone} for name, zone in (
            ("nvidia-l4", "us-central1-b"), ("nvidia-a100-80gb", "us-central1-c"),
            ("nvidia-a100-80gb", "us-central1-a"), ("nvidia-l4", "us-east1-c"))]
        self.assertEqual([(t["machine"], z) for t, z in run.capacity_candidates(inventory)], [
            ("a2-ultragpu-1g", "us-central1-a"), ("a2-ultragpu-1g", "us-central1-c"),
            ("g2-standard-12", "us-central1-b")])

    def test_runtime_caps_and_prior_spend(self):
        self.assertEqual(run.run_budget(run.TARGETS[0], 4)["max_seconds"], 7200)
        self.assertEqual(run.run_budget(run.TARGETS[1])["max_seconds"], 14400)
        with self.assertRaises(ValueError):
            run.run_budget(run.TARGETS[0], spent_usd=2)
        with self.assertRaises(ValueError):
            run.run_budget(run.TARGETS[1], max_hours=float("nan"))

    def test_lifecycle_event_includes_vm_name(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run.event(root, "create-request", name="rhymeai-test", zone="us-central1-a")
            row = json.loads((root / "lifecycle.jsonl").read_text())
            self.assertEqual(row["name"], "rhymeai-test")
            self.assertEqual(row["event"], "create-request")

    def test_product_paths_cannot_escape_destination(self):
        for name in ("../weights.gguf", "/tmp/weights.gguf", "a/b", "..", ""):
            with self.subTest(name=name), self.assertRaises(ValueError):
                run.safe_name(name)
        self.assertEqual(run.safe_name("epoch-2.gguf"), "epoch-2.gguf")

    def test_changed_notebook_refused_before_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "notebooks").mkdir()
            (root / "notebooks/1-rhymeai-e2b-v5.ipynb").write_text(json.dumps({"cells": []}))
            with self.assertRaisesRegex(ValueError, "frozen"):
                run.package_inputs(root, root)

    def test_internal_ssd_destination_refused(self):
        with self.assertRaises(ValueError):
            run.external_output("/tmp/gcp-models")


if __name__ == "__main__":
    unittest.main()
