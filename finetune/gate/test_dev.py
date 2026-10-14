import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from . import build
from .build import DEV_VERSION, FROZEN_VERSION, SEEDS, freeze, make_inputs, prepare_dev, read_jsonl, sha256, text_hash, write_json, write_jsonl
from .generate import SAMPLER
from .judge import judged_counts, make_pairs, selected_prompts
from .report import report
from .run_gate import main


def dev_songs():
    return [{"id": f"dev-{i}", "title": f"Copper wheel {i}", "theme": "A wheel repaired beside a pantry",
             "lines": [f"Our copper wheel {i} turns softly beside the pantry door",
                       f"Your paper map {i} folds gently around the kitchen chair",
                       f"A wicker basket {i} holds letters from the mountain store",
                       f"My little compass {i} points toward the empty market square",
                       f"The painted shutters {i} open while the kettle starts to sing",
                       f"We carry apricots {i} inside before the bells begin to ring"]} for i in range(2)]


class DevEvaluationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("2026-10-07/rhymeai-teacher-data-v3", "2026-10-08/rhymeai-colab-package-levels"):
            (self.root / name).mkdir(parents=True)
        self.pools = patch.object(build, "ARTIFACTS", self.root)
        self.pools.start()
        self.addCleanup(self.pools.stop)
        self.source = self.root / "songs.jsonl"
        write_jsonl(self.source, dev_songs())

    def test_dev_uses_supplied_songs_and_modes_cannot_mix(self):
        out = self.root / "dev"
        manifest = prepare_dev(out, self.source)
        self.assertEqual(manifest["version"], DEV_VERSION)
        self.assertEqual(manifest["songs"], 2)
        self.assertEqual(manifest["prompts"], 30)
        self.assertEqual(read_jsonl(out / "benchmark-songs.jsonl"), dev_songs())
        with self.assertRaisesRegex(ValueError, "Cannot mix"):
            freeze(out)
        frozen = self.root / "frozen"
        frozen.mkdir()
        write_json(frozen / "benchmark.json", {"version": FROZEN_VERSION})
        write_json(frozen / "summary.json", {"verdict": "PASS"})
        with patch("sys.argv", ["run_gate.py", "--dev-songs", str(self.source), "--candidate", "unused.gguf", "--out", str(frozen)]):
            with self.assertRaisesRegex(ValueError, "Cannot mix"):
                main()
        self.assertEqual(json.loads((frozen / "summary.json").read_text())["verdict"], "PASS")
        (frozen / "benchmark.json").unlink()
        with self.assertRaisesRegex(ValueError, "artifacts"):
            prepare_dev(frozen, self.source)

    def test_dev_rejects_overlap_with_frozen_and_training_songs(self):
        write_jsonl(self.source, read_jsonl(build.HERE / "benchmark-songs.jsonl")[:1])
        with self.assertRaisesRegex(ValueError, "DEV contamination"):
            prepare_dev(self.root / "frozen-overlap", self.source)
        write_jsonl(self.source, dev_songs())
        write_json(self.root / "2026-10-07/rhymeai-teacher-data-v3/train.json", {"text": dev_songs()[0]["lines"][0]})
        with self.assertRaisesRegex(ValueError, "DEV contamination"):
            prepare_dev(self.root / "training-overlap", self.source)

    def test_frozen_mode_still_enforces_frozen_json(self):
        gate = self.root / "gate-source"
        gate.mkdir()
        songs = read_jsonl(build.HERE / "benchmark-songs.jsonl")
        songs[0]["theme"] += " changed"
        write_jsonl(gate / "benchmark-songs.jsonl", songs)
        shutil.copy2(build.HERE / "frozen.json", gate / "frozen.json")
        with patch.object(build, "HERE", gate):
            with self.assertRaisesRegex(ValueError, "immutable"):
                freeze(self.root / "changed-frozen")

    def test_short_dev_cells_are_judged_without_changing_frozen_selection(self):
        rows = make_inputs(dev_songs())
        selected = selected_prompts(rows, dev=True)
        self.assertEqual(len(selected), 22)
        self.assertEqual(sum(judged_counts(selected).values()), 22)
        self.assertTrue(all(count <= 10 for count in judged_counts(selected).values()))
        with self.assertRaisesRegex(ValueError, "150"):
            selected_prompts(rows)
        self.assertEqual(len(selected_prompts(make_inputs(read_jsonl(build.HERE / "benchmark-songs.jsonl")))), 150)

    def test_dev_report_cannot_pass_even_when_every_metric_passes(self):
        out = self.root / "report"
        out.mkdir()
        row = dict(make_inputs(dev_songs())[0], prompt="Offline DEV prompt", candidate_words=["door"])
        row["prompt_sha256"] = text_hash(row["prompt"])
        write_jsonl(out / "benchmark-songs.jsonl", dev_songs())
        write_json(out / "inputs.json", [row])
        write_json(out / "prompts.json", [row])
        write_json(out / "benchmark.json", {"version": DEV_VERSION, "songs": 2, "prompts": 1, "task_counts": {"suggestions": 1},
                   "songs_sha256": sha256(out / "benchmark-songs.jsonl"), "inputs_sha256": sha256(out / "inputs.json"),
                   "prompts_sha256": sha256(out / "prompts.json")})
        write_jsonl(out / "parity.jsonl", [{"id": row["id"], "frozen_byte_parity": True, "prompt_sha256": row["prompt_sha256"]}])
        write_json(out / "overlap-final.json", {"overlapping_lines": 0, "files": [], "v4_present": False,
                   "frozen_benchmark_sha256": sha256(build.HERE / "benchmark-songs.jsonl")})
        for role in ("candidate", "incumbent"):
            write_json(out / f"binding-{role}.json", {"model_path": "offline-fixture", "model_sha256": "offline-fixture"})
            write_jsonl(out / f"replay-{role}.jsonl", [dict(id=row["id"], seed=seed, task="suggestions", level="Simple",
                       shown_lines=["Copper wheels settle beside the door"], shown_count=1, error=None, calls=1,
                       category="accepted", offline_replay_equal=True) for seed in SEEDS])
            write_jsonl(out / f"raw-{role}.jsonl", [dict(id=row["id"], seed=seed, **{"pass": 1}, request=dict(SAMPLER, seed=seed),
                       sampler_seed=seed, output="Copper wheels settle beside the door", termination="server_stop", elapsed_ms=0) for seed in SEEDS])
        pairs = make_pairs(out)
        write_jsonl(out / "pairs.jsonl", pairs)
        write_jsonl(out / "judgments.jsonl", [{"pair_id": p["pair_id"], "winner": "tie"} for p in pairs])
        write_json(out / "judge-provenance.json", {"model": "offline-fixture", "provider": "fixture", "incremental_api_cost_usd": 0,
                   "cost_basis": "no calls", "usage": {}})
        # Force the strongest possible metric result to exercise DEV's non-adoption guarantee.
        all_pass = {"gates": {f"G{i}": True for i in range(2, 6)}, "metrics": {}, "preference": {},
                    "suggestion_errors": {}, "suggestion_categories": {}}
        with patch("gate.report.summarize", return_value=all_pass):
            self.assertEqual(report(out), "DEV")
        summary = json.loads((out / "summary.json").read_text())
        self.assertTrue(all(summary["gates"].values()))
        self.assertEqual(summary["verdict"], "DEV")
        self.assertEqual(summary["judged_prompt_counts_per_cell"]["suggestions/Simple/PERFECT"], 1)
        self.assertIn("DEV EVALUATION - not an adoption verdict", (out / "report.md").read_text())


if __name__ == "__main__":
    unittest.main()
