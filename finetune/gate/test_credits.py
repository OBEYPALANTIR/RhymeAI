import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from .build import write_json, write_jsonl
from .judge import (JUDGE_MODEL, LEGACY_RUBRIC, codex_batch, credit_accounting,
                    credit_budget, judge, paid_cost_provenance)
from .recheck import recheck
from .run_gate import main
from .test_resume import judge_fixture


def meter(balance, fingerprint="same-account", ordinary=False, plan="plus"):
    return {"account_fingerprint": fingerprint, "credits": balance, "plan": plan,
            "ordinary_usage_allowed": ordinary, "used_percent": 100 if not ordinary else 25}


class CreditBudgetTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)
        self.pairs = [{"pair_id": "one", "task": "suggestions", "inner": "Write the next line",
                       "left": "The last train takes the rain away", "right": "I keep your ticket for another day"}]
        self.executions = []

    def run_batch(self, readings, budget=10, name="batch", returncode=0, failure=None):
        def run(command, **kwargs):
            if command[1:3] == ["login", "status"]:
                return subprocess.CompletedProcess(command, 0, "Logged in using ChatGPT", "")
            self.executions.append(command)
            billing = json.loads((self.out / f"{name}.billing.json").read_text())
            self.assertIsNone(billing["after"])
            self.assertEqual(command[command.index("-m") + 1], JUDGE_MODEL)
            if failure:
                raise failure
            write_json(Path(command[command.index("--output-last-message") + 1]),
                       {"judgments": [{"pair_id": "one", "winner": "L", "reason": "continues the scene"}]})
            kwargs["stdout"].write(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 10}}) + "\n")
            return subprocess.CompletedProcess(command, returncode)
        with patch("gate.judge.logic_guard"), patch("gate.judge.subprocess.run", side_effect=run), \
             patch("gate.judge.account_usage", side_effect=readings):
            return codex_batch(self.out, self.pairs, False, name, judge_credit_budget=budget)

    def test_zero_budget_refuses_exhausted_allowance_without_a_paid_call(self):
        with self.assertRaisesRegex(RuntimeError, "allowance exhausted"):
            self.run_batch([meter(100)], budget=0)
        self.assertFalse(self.executions)
        self.assertFalse((self.out / "batch.billing.json").exists())
        binding = json.loads((self.out / "batch.binding.json").read_text())
        self.assertEqual(binding["incremental_api_cost_usd"], 0)
        self.assertNotIn("judge_credit_budget", binding)

    def test_zero_budget_keeps_cached_bytes_and_still_rejects_debits(self):
        pairs, binding = judge_fixture(self.out)
        write_json(self.out / "batch.binding.json", binding)
        before = {p.name: p.read_bytes() for p in self.out.iterdir()}
        with patch("gate.judge.account_usage", side_effect=AssertionError("No new call")):
            result, _ = codex_batch(self.out, pairs, False, "batch", LEGACY_RUBRIC, judge_credit_budget=0)
        self.assertEqual(result[0]["winner"], "L")
        for name, value in before.items():
            self.assertEqual((self.out / name).read_bytes(), value)
        write_json(self.out / "batch.billing.json", {"before": meter(100), "after": meter(99)})
        with self.assertRaisesRegex(RuntimeError, "balance/account changed"):
            codex_batch(self.out, pairs, False, "batch", LEGACY_RUBRIC)

    def test_paid_spend_and_resume_use_recorded_deltas_once(self):
        self.run_batch([meter(100), meter(97.5)])
        self.run_batch([meter(96), meter(92.75)], name="second")
        self.run_batch([], name="second")
        self.assertEqual(len(self.executions), 2)
        state = credit_accounting(self.out, 10)
        self.assertEqual(state["credits_spent"], 5.75)
        self.assertEqual(state["largest_batch_delta"], 3.25)
        self.assertEqual(state["account_fingerprint"], "same-account")
        self.assertTrue(state["accounting_complete"])
        for batch in state["batches"]:
            self.assertEqual(batch["before"]["plan"], "plus")
            self.assertEqual(batch["after"]["plan"], "plus")
            self.assertEqual(batch["credit_delta"], batch["credits_spent"])
        cost = paid_cost_provenance(self.out, 10)
        self.assertNotIn("incremental_api_cost_usd", cost)
        self.assertNotIn("Included ChatGPT subscription", cost["cost_basis"])
        self.assertNotIn("incremental_api_cost_usd", json.loads((self.out / "batch.binding.json").read_text()))

    def test_largest_batch_reservation_stops_before_another_call(self):
        self.run_batch([meter(100), meter(97)], budget=6)
        self.run_batch([meter(97), meter(95)], budget=6, name="second")
        with self.assertRaisesRegex(RuntimeError, "refusing to start"):
            self.run_batch([meter(95)], budget=6, name="third")
        self.assertEqual(len(self.executions), 2)
        self.assertFalse((self.out / "third.billing.json").exists())

    def test_fingerprint_change_within_or_between_batches_stops(self):
        with self.assertRaisesRegex(RuntimeError, "fingerprint changed"):
            self.run_batch([meter(100), meter(99, fingerprint="other-account")])
        self.assertFalse(credit_accounting(self.out, 10)["accounting_complete"])
        self.assertEqual(len(self.executions), 1)

    def test_fingerprint_change_before_next_batch_does_not_launch(self):
        self.run_batch([meter(100), meter(99)])
        with self.assertRaisesRegex(RuntimeError, "fingerprint changed before"):
            self.run_batch([meter(99, fingerprint="other-account")], name="second")
        self.assertEqual(len(self.executions), 1)

    def test_failed_call_is_charged_and_cannot_overwrite_billing(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_batch([meter(100), meter(98)], failure=subprocess.TimeoutExpired("codex", 600))
        original = (self.out / "batch.billing.json").read_bytes()
        self.assertEqual(credit_accounting(self.out, 10)["credits_spent"], 2)
        with self.assertRaisesRegex(RuntimeError, "must not be overwritten"):
            self.run_batch([meter(98)])
        self.assertEqual((self.out / "batch.billing.json").read_bytes(), original)
        self.assertEqual(len(self.executions), 1)

    def test_missing_post_call_meter_blocks_new_batches(self):
        with self.assertRaisesRegex(RuntimeError, "meter unavailable"):
            self.run_batch([meter(100), RuntimeError("meter unavailable")])
        with self.assertRaisesRegex(RuntimeError, "Missing post-batch billing"):
            self.run_batch([meter(99)], name="second")
        self.assertEqual(len(self.executions), 1)
        self.assertFalse(credit_accounting(self.out, 10)["accounting_complete"])

    def test_unexpected_large_first_batch_is_recorded_and_stops(self):
        with self.assertRaisesRegex(RuntimeError, "budget exceeded"):
            self.run_batch([meter(100), meter(89)])
        self.assertEqual(credit_accounting(self.out, 10)["credits_spent"], 11)
        with self.assertRaisesRegex(RuntimeError, "refusing to start"):
            self.run_batch([meter(89)], name="second")
        self.assertEqual(len(self.executions), 1)

    def test_balance_increase_is_not_allowed_to_hide_spending(self):
        with self.assertRaisesRegex(RuntimeError, "balance increased"):
            self.run_batch([meter(100), meter(101)])
        state = credit_accounting(self.out, 10)
        self.assertEqual(state["batches"][0]["credit_delta"], -1)
        self.assertEqual(state["credits_spent"], 0)
        self.assertFalse(state["accounting_complete"])

    def test_budget_must_be_finite_nonnegative_and_stable_across_resumes(self):
        for value in (-1, float("inf"), float("nan")):
            with self.assertRaises(ValueError):
                credit_budget(value)
        self.run_batch([meter(100), meter(99)])
        with self.assertRaisesRegex(ValueError, "budget changed"):
            self.run_batch([meter(99)], budget=11, name="second")
        self.assertEqual(len(self.executions), 1)

    def test_ordinary_exhaustion_can_resume_with_explicit_paid_budget(self):
        with self.assertRaisesRegex(RuntimeError, "allowance exhausted"):
            self.run_batch([meter(100)], budget=0)
        self.run_batch([meter(100), meter(99)])
        self.assertEqual(credit_accounting(self.out, 10)["credits_spent"], 1)

    def test_partial_judge_provenance_preserves_billing_after_failure(self):
        def fail(directory, *args, **kwargs):
            directory.mkdir()
            write_json(directory / "batch.billing.json", {"before": meter(100), "after": meter(98)})
            raise RuntimeError("judge refused")
        with patch("gate.judge.make_pairs", return_value=self.pairs), patch("gate.judge.codex_batch", side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, "judge refused"):
                judge(self.out, judge_credit_budget=10)
        provenance = json.loads((self.out / "judge-provenance.json").read_text())
        self.assertFalse(provenance["complete"])
        self.assertEqual(provenance["credits_spent"], 2)
        self.assertEqual(provenance["batches"][0]["before"], meter(100))
        Path(provenance["blind_workspace"]).joinpath("batch.billing.json").unlink()
        Path(provenance["blind_workspace"]).rmdir()

    def test_offline_recheck_checks_budget_before_invalidating_saved_results(self):
        write_json(self.out / "judge-provenance.json", {"credits_spent": 12, "accounting_complete": True})
        (self.out / "report.md").write_text("saved report")
        with self.assertRaisesRegex(ValueError, "exceeds the recheck"):
            recheck(self.out, judge_credit_budget=10)
        self.assertEqual((self.out / "report.md").read_text(), "saved report")

    def test_failed_runner_reports_paid_spending(self):
        def fail(out, judge_credit_budget):
            self.assertEqual(judge_credit_budget, 10)
            write_json(out / "judge-provenance.json", {"judge_credit_budget": 10, "credits_spent": 2,
                       "accounting_complete": True})
            raise RuntimeError("judge refused")
        with patch("sys.argv", ["run_gate.py", "--candidate", "unused.gguf", "--out", str(self.out),
                                "--judge-credit-budget", "10"]), \
             patch("gate.run_gate.freeze"), patch("gate.run_gate.freeze_prompts"), \
             patch("gate.run_gate.select_incumbent", return_value=Path("incumbent.gguf")), \
             patch("gate.run_gate.generate"), patch("gate.judge.judge", side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, "judge refused"):
                main()
        rendered = (self.out / "report.md").read_text()
        self.assertIn("Judge credits spent (recorded): 2", rendered)
        self.assertNotIn("$0", rendered)
        self.assertFalse(json.loads((self.out / "status.json").read_text())["complete"])


if __name__ == "__main__":
    unittest.main()
