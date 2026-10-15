import tempfile
import unittest
from pathlib import Path

from .backend import require_same_backend, server_backend, tunnel_port, verify_remote
from .cloud_lane import budget
from .generate import generate
from .judge import make_pairs
from .report import report
from .build import write_json

CUDA = {"kind": "cuda", "build_info": "b1-123456789", "binary_sha256": "1" * 64}


def proof_fixture():
    proof = {"model_sha256": "2" * 64, "model_bytes": 42, "model_path": "/content/models/test.gguf",
             "gcs_readback_sha256": "2" * 64, "gcs_generation": "123",
             "model_alias": "hash-and-launch-nonce", "pid": 123, "instance_id": "456", "verified_at": "2026-10-15",
             "backend": CUDA}
    props = {"model_path": proof["model_path"], "model_alias": proof["model_alias"], "build_info": CUDA["build_info"],
             "total_slots": 1, "default_generation_settings": {"n_ctx": 2048}}
    return proof, props


class RemoteBindingTest(unittest.TestCase):
    def test_mixed_missing_or_changed_backend_cannot_be_paired_or_reported(self):
        for other in (None, dict(CUDA, kind="metal"), dict(CUDA, build_info="different-build"), dict(CUDA, binary_sha256="3" * 64)):
            bindings = {"candidate": {"backend": CUDA}, "incumbent": {"backend": other}}
            with self.subTest(other=other), self.assertRaisesRegex(ValueError, "backend"):
                require_same_backend(bindings)
            with tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                write_json(out / "benchmark.json", {"version": "rhymeai-dev"})
                for role, binding in bindings.items():
                    write_json(out / f"binding-{role}.json", binding)
                for consumer in (make_pairs, report):
                    with self.subTest(consumer=consumer.__name__), self.assertRaisesRegex(ValueError, "backend"):
                        consumer(out)
        require_same_backend({"candidate": {"backend": CUDA}, "incumbent": {"backend": dict(CUDA)}})

    def test_remote_hash_is_bound_to_expected_bytes_and_live_props(self):
        proof, props = proof_fixture()
        self.assertEqual(verify_remote(proof, props, "2" * 64, 42), CUDA)
        for change in ({"model_sha256": "3" * 64}, {"gcs_readback_sha256": None}, {"gcs_generation": None},
                       {"model_bytes": 43}, {"verified_at": None}, {"backend": None}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                verify_remote(dict(proof, **change), props, "2" * 64, 42)
        for change in ({"model_path": "/different.gguf"}, {"model_alias": "old-launch"}, {"build_info": "new-build"}, {"total_slots": 2}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                verify_remote(proof, dict(props, **change), "2" * 64, 42)

    def test_remote_run_without_verified_hash_fails_before_accessing_model_or_spawning(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            with self.assertRaisesRegex(ValueError, "verified remote model SHA-256"):
                generate(out, "candidate", out / "absent.gguf", server_url="http://127.0.0.1:18080")
            self.assertEqual(list(out.iterdir()), [])
        _, props = proof_fixture()
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            verify_remote(None, props, "2" * 64, 42)

    def test_backend_comes_from_actual_offload_and_build(self):
        _, props = proof_fixture()
        for kind, device in (("cuda", "CUDA0"), ("metal", "Metal")):
            self.assertEqual(server_backend(props, f"{device}\noffloaded 36/36 layers to GPU", "1" * 64)["kind"], kind)
        self.assertEqual(server_backend(props, "CPU model buffer", "1" * 64)["kind"], "cpu")
        with self.assertRaises(ValueError):
            server_backend(props, "CUDA available but no model loaded", "1" * 64)

    def test_tunnel_is_loopback_only_and_cost_cap_is_finite(self):
        self.assertEqual(tunnel_port("http://127.0.0.1:18080"), 18080)
        for url in ("http://example.com:8080", "http://0.0.0.0:8080", "https://127.0.0.1:8080", "http://user@127.0.0.1:8080"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                tunnel_port(url)
        self.assertLess(budget(1, 0, 3427880800)["conservative_bound_usd"], 5)
        for hours, spent in ((float("nan"), 0), (float("inf"), 0), (0, 0), (7, 0), (6, 9)):
            with self.subTest(hours=hours, spent=spent), self.assertRaises(ValueError):
                budget(hours, spent, 3427880800)


if __name__ == "__main__":
    unittest.main()
