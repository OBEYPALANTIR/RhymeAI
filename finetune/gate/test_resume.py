import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from .build import sha256, text_hash, write_json, write_jsonl
from .generate import SAMPLER, generate, local_server, source_binding
from .judge import JUDGE_MODEL, JUDGE_PROMPT, codex_batch
from .run_gate import main

BACKEND = {"kind": "metal", "build_info": "b1-123456789", "binary_sha256": "0" * 64}


def legacy_evidence(out, role):
    evidence = out / "evidence"
    evidence.mkdir(exist_ok=True)
    write_json(evidence / f"props-{role}.json", {"build_info": BACKEND["build_info"]})
    write_json(evidence / f"server-{role}-1-command.json", ["/opt/homebrew/bin/llama-server", "--n-gpu-layers", "99"])
    write_json(out / "provenance.json", {"source_head": "1" * 40})
    probe = out / "host-probe.json"
    write_json(probe, {"binary_path": "/opt/homebrew/bin/llama-server", "binary_sha256": BACKEND["binary_sha256"],
                      "build_info": BACKEND["build_info"], "version_output": "build 1, commit 123456789",
                      "list_devices_output": "Available devices:\n  MTL0: Apple M3 Max (38338 MiB, 38338 MiB free)\n",
                      "gate_commits": {"1" * 40: {"source_sha256": "2" * 64, "n_gpu_layers": 99}}})
    return probe

def capture_fixture(out):
    model = out / "unrelated.gguf"
    model.write_bytes(b"not the GGUF that produced these captures")
    write_json(out / "prompts.json", [{}])
    binding = {"model_path": str(model.resolve()), "model_sha256": sha256(model),
               "model_bytes": model.stat().st_size, "prompts_sha256": sha256(out / "prompts.json"),
               "sampler": SAMPLER, "source": source_binding(), "sampler_seed_offset": 0, "backend": BACKEND}
    return model, binding


def judge_fixture(out):
    pairs = [{"pair_id": "one", "inner": "Write a lyric", "left": "Copper birds settle slowly", "right": "Silver birds fly home"}]
    prompt = ("Judge each independent pair below. Use only the supplied text and rubric. Do not use tools, "
              "read files, or infer model identities. Return exactly one judgment for every pair_id in the schema.\n"
              + json.dumps([{"pair_id": "one", "task": JUDGE_PROMPT % (pairs[0]["inner"], pairs[0]["left"], pairs[0]["right"])}], ensure_ascii=False))
    binding = {"model": JUDGE_MODEL, "reasoning_effort": "low", "prompt_sha256": text_hash(prompt),
               "subscription_auth": True, "incremental_api_cost_usd": 0.0}
    write_json(out / "batch.result.json", {"judgments": [{"pair_id": "one", "winner": "L", "reason": "concrete"}]})
    billing = {"account_fingerprint": "same-account", "credits": 0.0}
    write_json(out / "batch.billing.json", {"before": billing, "after": billing})
    write_jsonl(out / "batch.events.jsonl", [{"type": "turn.completed", "usage": {"input_tokens": 10}}])
    write_json(out / "batch.exit.json", {"returncode": 0})
    return pairs, binding


class CaptureBindingTest(unittest.TestCase):
    def test_orphaned_replay_or_raw_cannot_acquire_a_new_binding(self):
        for name in ("replay-candidate.jsonl", "raw-candidate.jsonl"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                model, _ = capture_fixture(out)
                write_jsonl(out / name, [{}, {}, {}])
                with patch("gate.generate.logic_guard", side_effect=AssertionError("Inference must not start")):
                    with self.assertRaisesRegex(ValueError, "binding"):
                        generate(out, "candidate", model)
                self.assertFalse((out / "binding-candidate.json").exists())

    def test_changed_binding_is_rejected_without_overwriting_it(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            model, binding = capture_fixture(out)
            binding["model_sha256"] = "different-model"
            write_json(out / "binding-candidate.json", binding)
            write_jsonl(out / "replay-candidate.jsonl", [{}, {}, {}])
            with self.assertRaises(ValueError):
                generate(out, "candidate", model)
            self.assertEqual(json.loads((out / "binding-candidate.json").read_text()), binding)

    def test_identical_existing_binding_allows_completed_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            model, binding = capture_fixture(out)
            write_json(out / "binding-candidate.json", binding)
            write_jsonl(out / "replay-candidate.jsonl", [{}, {}, {}])
            self.assertEqual(generate(out, "candidate", model), binding)

    def test_completed_legacy_replay_derives_backend_without_rewriting_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            model, binding = capture_fixture(out)
            del binding["backend"]
            target = out / "binding-candidate.json"
            write_json(target, binding)
            before = target.read_bytes()
            write_jsonl(out / "replay-candidate.jsonl", [{}, {}, {}])
            probe = legacy_evidence(out, "candidate")
            with patch("gate.backend.HOST_PROBE", probe, create=True), patch("gate.generate.local_server", side_effect=AssertionError("No inference")):
                result = generate(out, "candidate", model)
            self.assertTrue(result["backend"]["legacy"])
            self.assertEqual(result["backend"]["binary_sha256"], BACKEND["binary_sha256"])
            self.assertEqual(target.read_bytes(), before)

    def test_new_run_binds_observation_and_continued_legacy_run_retains_inference(self):
        for legacy in (False, True):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                model, binding = capture_fixture(out)
                target = out / "binding-candidate.json"
                probe = legacy_evidence(out, "candidate")
                if legacy:
                    del binding["backend"]
                    write_json(target, binding)
                def finish(*args):
                    write_jsonl(out / "replay-candidate.jsonl", [{"id": "one", "seed": seed} for seed in (7000, 7001, 7002)])
                with patch("gate.backend.HOST_PROBE", probe), patch("gate.generate.local_server") as server:
                    server.return_value.__enter__.return_value = (8080, {}, BACKEND)
                    with patch("gate.generate.generate_from_server", side_effect=finish):
                        result = generate(out, "candidate", model)
                self.assertEqual(json.loads(target.read_text()), result)
                self.assertEqual(result["backend"].get("legacy", False), legacy)
                if not legacy:
                    self.assertEqual(result["backend"], BACKEND)

    def test_resumed_server_preserves_props_cited_by_legacy_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            model, _ = capture_fixture(out)
            legacy_evidence(out, "candidate")
            original = (out / "evidence/props-candidate.json").read_bytes()
            props = dict(build_info=BACKEND["build_info"], model_alias="new-launch")
            process = MagicMock(pid=123, returncode=0)
            process.poll.return_value = None
            health = MagicMock()
            health.__enter__.return_value.status = 200
            def launch(*args, **kwargs):
                kwargs["stdout"].write("Metal\noffloaded 36/36 layers to GPU\n")
                kwargs["stdout"].flush()
                return process
            with patch("gate.generate.logic_guard"), patch("gate.generate.shutil.which", return_value=str(model)), \
                 patch("gate.generate.subprocess.Popen", side_effect=launch), \
                 patch("gate.generate.urllib.request.urlopen", side_effect=[health, io.StringIO(json.dumps(props))]):
                with local_server(out, "candidate", model) as (_, observed, backend):
                    self.assertEqual(observed, props)
                    self.assertEqual(backend["kind"], "metal")
            self.assertEqual((out / "evidence/props-candidate.json").read_bytes(), original)
            saved = list((out / "evidence").glob("props-candidate-*.json"))
            self.assertEqual(len(saved), 1)
            self.assertEqual(json.loads(saved[0].read_text()), props)

    def test_orphaned_judge_result_cannot_acquire_a_new_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            pairs, _ = judge_fixture(out)
            with self.assertRaisesRegex(ValueError, "binding"):
                codex_batch(out, pairs, False, "batch")
            self.assertFalse((out / "batch.binding.json").exists())


class JudgeCompletionTest(unittest.TestCase):
    def test_cached_result_requires_zero_exit_and_successful_terminal_event(self):
        cases = [
            (None, [{"type": "turn.completed"}]),
            (1, [{"type": "turn.completed"}]),
            (0, []),
            (0, [{"type": "turn.failed", "error": {"message": "failed"}}]),
            (0, [{"type": "turn.completed"}, {"type": "turn.failed"}]),
        ]
        for exit_code, events in cases:
            with self.subTest(exit_code=exit_code, events=events), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                pairs, binding = judge_fixture(out)
                write_json(out / "batch.binding.json", binding)
                if exit_code is None:
                    (out / "batch.exit.json").unlink()
                else:
                    write_json(out / "batch.exit.json", {"returncode": exit_code})
                write_jsonl(out / "batch.events.jsonl", events)
                with self.assertRaisesRegex(RuntimeError, "complet"):
                    codex_batch(out, pairs, False, "batch")

    def test_recoverable_error_followed_by_success_remains_reusable(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            pairs, binding = judge_fixture(out)
            write_json(out / "batch.binding.json", binding)
            write_jsonl(out / "batch.events.jsonl", [{"type": "error", "message": "retrying"},
                                                       {"type": "turn.completed", "usage": {"input_tokens": 10}}])
            result, usage = codex_batch(out, pairs, False, "batch")
            self.assertEqual(result[0]["winner"], "L")
            self.assertEqual(usage, [{"input_tokens": 10}])


class RerunVerdictTest(unittest.TestCase):
    def test_failed_real_freeze_removes_previous_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            write_json(out / "summary.json", {"verdict": "PASS", "gates": {f"G{i}": True for i in range(1, 7)}})
            (out / "report.md").write_text("# Frozen model gate: PASS\n")
            write_json(out / "inputs.json", [])
            write_json(out / "prompts.json", [])
            with patch("sys.argv", ["run_gate.py", "--candidate", str(out / "unused.gguf"), "--out", str(out)]):
                with self.assertRaisesRegex(ValueError, "Frozen inputs changed"):
                    main()
            self.assertFalse((out / "summary.json").exists())
            self.assertNotIn("PASS", (out / "report.md").read_text())
            self.assertFalse(json.loads((out / "status.json").read_text())["complete"])

    def test_previous_verdict_is_invalidated_before_first_work(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            write_json(out / "summary.json", {"verdict": "PASS"})
            (out / "report.md").write_text("PASS")
            def interrupted_freeze(target):
                self.assertFalse((target / "summary.json").exists())
                self.assertFalse((target / "report.md").exists())
                raise KeyboardInterrupt()
            with patch("sys.argv", ["run_gate.py", "--candidate", "unused.gguf", "--out", str(out)]):
                with patch("gate.run_gate.freeze", side_effect=interrupted_freeze):
                    with self.assertRaises(KeyboardInterrupt):
                        main()
            self.assertFalse((out / "summary.json").exists())


if __name__ == "__main__":
    unittest.main()
