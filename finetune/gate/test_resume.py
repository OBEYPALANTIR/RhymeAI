import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from .build import sha256, text_hash, write_json, write_jsonl
from .generate import SAMPLER, generate, source_binding
from .judge import JUDGE_MODEL, JUDGE_PROMPT, codex_batch
from .run_gate import main

BACKEND = {"kind": "metal", "build_info": "test-build", "binary_sha256": "0" * 64}

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
