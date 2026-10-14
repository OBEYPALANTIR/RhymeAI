"""Blinded contestants must remain distinct even when GGUF filenames match."""

import argparse
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

FINETUNE = str(Path(__file__).resolve().parents[1])
if FINETUNE not in sys.path:
    sys.path.insert(0, FINETUNE)

from eval import run_naturalness  # noqa: E402


class NaturalnessTests(unittest.TestCase):
    def test_same_basename_keeps_wins_with_the_unblinded_contestant(self):
        def outputs(model, envelope, cases, samples, log_path):
            return {(case["id"], k): model for case in cases for k in range(samples)}

        with tempfile.TemporaryDirectory() as directory:
            pairs_path = Path(directory) / "pairs.jsonl"
            judgments_path = Path(directory) / "judgments.jsonl"
            args = argparse.Namespace(
                model_x="base/model.gguf", model_y="tuned/model.gguf",
                envelope_x="gemma4", envelope_y="gemma4", samples=1, seed=3407,
                out=str(pairs_path), pairs=str(pairs_path), judgments=str(judgments_path))
            with patch.object(run_naturalness, "generate_for_model", side_effect=outputs):
                with contextlib.redirect_stdout(io.StringIO()):
                    run_naturalness.cmd_generate(args)
            pairs = [json.loads(line) for line in pairs_path.read_text().splitlines()]
            judgments = [{"pair_id": pair["pair_id"],
                          "winner": "L" if pair["left"] == args.model_x else "R"}
                         for pair in pairs]
            self.assertEqual({row["winner"] for row in judgments}, {"L", "R"})
            judgments_path.write_text("\n".join(json.dumps(row) for row in judgments))
            report = io.StringIO()
            with contextlib.redirect_stdout(report):
                run_naturalness.cmd_report(args)
            rows = [line.split() for line in report.getvalue().splitlines()]
            self.assertIn(["ALL", "x:", "model.gguf", str(len(pairs))], rows)
            self.assertIn(["ALL", "y:", "model.gguf", "0"], rows)


if __name__ == "__main__":
    unittest.main()
