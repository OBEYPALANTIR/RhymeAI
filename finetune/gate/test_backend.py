import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from .backend import read_binding, require_backend, require_same_backend, verify_remote
from .build import sha256, write_json
from .probe_host import gate_launch
from .test_cloud import proof_fixture
from .test_resume import BACKEND, legacy_evidence


class LegacyBackendTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.out = Path(temp.name)
        self.probe = legacy_evidence(self.out, "candidate")
        write_json(self.out / "binding-candidate.json", {})
        patcher = patch("gate.backend.HOST_PROBE", self.probe)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_legacy_records_inference_and_pairs_only_with_same_build_and_binary(self):
        before = (self.out / "binding-candidate.json").read_bytes()
        binding = read_binding(self.out, "candidate")
        backend = binding["backend"]
        self.assertTrue(backend["legacy"])
        self.assertEqual(backend["inferred_from"][0]["sha256"], sha256(self.probe))
        self.assertEqual(backend["inferred_from"][1]["sha256"], sha256(self.out / "evidence/props-candidate.json"))
        require_same_backend({"candidate": binding, "incumbent": {"backend": BACKEND}})
        self.assertEqual((self.out / "binding-candidate.json").read_bytes(), before)
        for change in ({"kind": "cuda"}, {"build_info": "different"}, {"binary_sha256": "f" * 64}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "backends/builds differ"):
                require_same_backend({"candidate": binding, "incumbent": {"backend": dict(BACKEND, **change)}})

    def test_missing_or_mismatched_evidence_fails_closed(self):
        original = json.loads(self.probe.read_text())
        for change in ({"build_info": "different"}, {"version_output": "build 2, commit abcdef"},
                       {"list_devices_output": "BLAS: Accelerate"}, {"gate_commits": {}}, {"binary_sha256": None}):
            with self.subTest(change=change):
                write_json(self.probe, dict(original, **change))
                with self.assertRaisesRegex(ValueError, "regenerate legacy captures"):
                    read_binding(self.out, "candidate")
        write_json(self.probe, original)
        for name in ("evidence/props-candidate.json", "provenance.json", "evidence/server-candidate-1-command.json", "host-probe.json"):
            path = self.out / name
            saved = path.read_bytes()
            path.unlink()
            with self.subTest(missing=name), self.assertRaisesRegex(ValueError, "regenerate legacy captures"):
                read_binding(self.out, "candidate")
            path.write_bytes(saved)

    def test_ambiguous_launch_or_unrecorded_inference_is_refused(self):
        for command in (["/different/llama-server", "--n-gpu-layers", "99"],
                        ["/opt/homebrew/bin/llama-server", "--n-gpu-layers", "0"],
                        ["/opt/homebrew/bin/llama-server", "--n-gpu-layers", "99", "--n-gpu-layers", "0"],
                        ["/opt/homebrew/bin/llama-server", "--n-gpu-layers", "99", "-ngl", "0"]):
            write_json(self.out / "evidence/server-candidate-2-command.json", command)
            with self.subTest(command=command), self.assertRaisesRegex(ValueError, "regenerate legacy captures"):
                read_binding(self.out, "candidate")
        with self.assertRaisesRegex(ValueError, "regenerate legacy captures"):
            require_backend(dict(BACKEND, legacy=True))

    def test_remote_proof_cannot_claim_legacy_inference(self):
        legacy = read_binding(self.out, "candidate")["backend"]
        proof, props = proof_fixture()
        proof["backend"] = legacy
        with self.assertRaisesRegex(ValueError, "fresh observed backend"):
            verify_remote(proof, props, "2" * 64, 42)

    def test_probe_records_the_actual_gate_flag(self):
        source = 'def local_server():\n    command = [binary, "--n-gpu-layers", "99"]\n'
        self.assertEqual(gate_launch(source)["n_gpu_layers"], 99)
        for invalid in (source.replace('"99"', '"0"'), source.replace('"--n-gpu-layers", "99"', '"--port", "8080"'),
                        source + source.replace("local_server", "other_server")):
            with self.subTest(source=invalid), self.assertRaisesRegex(ValueError, "99 GPU layers"):
                gate_launch(invalid)


if __name__ == "__main__":
    unittest.main()
