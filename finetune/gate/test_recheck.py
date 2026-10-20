import json
import tempfile
import unittest
from pathlib import Path

from .build import sha256, write_json
from .generate import SAMPLER
from .recheck import GATE_TEST, replay_binding, verify_unchanged
from .test_resume import capture_fixture


class OfflineRecheckTest(unittest.TestCase):
    def test_explicit_rebind_requires_original_inputs_and_only_gate_test_source_change(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            model, binding = capture_fixture(out)
            binding["source"][GATE_TEST] = "previous-gate-test-hash"
            del binding["sampler_seed_offset"]
            write_json(out / "binding-candidate.json", binding)
            write_json(out / "sampler.json", SAMPLER)
            rebound = replay_binding(out, "candidate")
            self.assertNotEqual(rebound["source"][GATE_TEST], binding["source"][GATE_TEST])
            self.assertEqual(rebound["sampler_seed_offset"], 0)
            self.assertEqual(json.loads((out / "binding-candidate.json").read_text()), binding)
            binding["source"]["android/app/src/main/kotlin/com/rhymeai/app/service/AIService.kt"] = "changed"
            write_json(out / "binding-candidate.json", binding)
            with self.assertRaisesRegex(ValueError, "source change"):
                replay_binding(out, "candidate")
            _, binding = capture_fixture(out)
            write_json(out / "binding-candidate.json", binding)
            model.write_bytes(b"different weights")
            with self.assertRaisesRegex(ValueError, "original binding"):
                replay_binding(out, "candidate")

    def test_changed_raw_bytes_cannot_be_certified(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            raw = out / "raw-candidate.jsonl"
            raw.write_bytes(b'{"raw_chunks": []}\n')
            hashes = {raw.name: sha256(raw)}
            verify_unchanged(out, hashes)
            raw.write_bytes(raw.read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "input bytes changed"):
                verify_unchanged(out, hashes)


if __name__ == "__main__":
    unittest.main()
