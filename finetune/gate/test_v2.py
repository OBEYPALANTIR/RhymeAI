import contextlib
import io
import json
import os
import runpy
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from unittest.mock import patch

from . import build
from .build import (FROZEN_VERSION, V2_VERSION, freeze, make_inputs, make_v2_inputs,
                    read_jsonl, require_mode, sha256, text_hash, write_json)
from .judge import LEGACY_RUBRIC, judged_counts, selected_prompts
from .metrics import FUNCTION_WORDS, MARGINS, yield_pass
from .run_gate import main


class FrozenV2Test(unittest.TestCase):
    def test_v1_frozen_bytes_inputs_and_judge_selection_are_unchanged(self):
        self.assertEqual(sha256(build.HERE / "frozen.json"),
                         "00ea6e4179bb468ccfe1e16bda86c4d29974d847a38f63a7a6b915e721d0e5e6")
        self.assertEqual(sha256(build.HERE / "benchmark-songs.jsonl"),
                         "f11e2d2b6cea4850b4a0d2bd6c41edb0c15c49adc3b88da33b048672c65e221c")
        rows = make_inputs(read_jsonl(build.HERE / "benchmark-songs.jsonl"))
        self.assertEqual(text_hash(json.dumps(rows, indent=2, ensure_ascii=False) + "\n"),
                         "3311abcd1a327af69dd2aff75a38ba86b1ea272ebd2a047d166d195ba199a301")
        frozen = json.loads((build.HERE / "frozen.json").read_text())
        self.assertEqual(frozen["prompts_sha256"],
                         "51a9220357d31731139ddcd8faab07dd8f6ebfe18a20ef709f532d69ff830b83")
        self.assertEqual(text_hash(json.dumps([r["id"] for r in selected_prompts(rows, rubric_version=LEGACY_RUBRIC)])),
                         "a66a6e9da0af2cca4cae1b558db8654b014f71222a9f8bae655187b8d3cff708")

    def test_v2_mix_and_production_word_selection_positions(self):
        songs = read_jsonl(build.HERE / "benchmark-songs-v2.jsonl")
        rows = make_v2_inputs(songs)
        self.assertEqual(len(songs), 60)
        self.assertEqual(len({r["id"] for r in rows}), 1140)
        self.assertEqual(Counter(r["task"] for r in rows),
                         dict(suggestions=480, rewrite_passage=180, rewrite_word=360, synonyms=120))
        cells = Counter((r["level"], r["rhyme_type"]) for r in rows if r["task"] == "suggestions")
        self.assertEqual(len(cells), 12)
        self.assertEqual(set(cells.values()), {40})
        self.assertEqual(Counter(r["inputs"]["action"] for r in rows if r["task"] == "rewrite_passage"),
                         dict(REPHRASE=60, PUNCH_UP=60, HARDER_RHYME=60))
        self.assertEqual(Counter(r["inputs"]["action"] for r in rows if r["task"] == "rewrite_word"),
                         dict(REPHRASE=120, PUNCH_UP=120, HARDER_RHYME=120))
        for row in rows:
            if row["task"] != "rewrite_word":
                continue
            c = row["inputs"]
            text = c["lyrics"].encode("utf-16-le")
            start = c["selection_start"] * 2
            end = start + len(c["selection"].encode("utf-16-le"))
            self.assertEqual(text[start:end].decode("utf-16-le"), c["selection"])
            if c["action"] == "HARDER_RHYME":
                self.assertFalse(text[end:].decode("utf-16-le").split("\n")[0].strip())
            else:
                self.assertNotIn(c["selection"].lower(), FUNCTION_WORDS)

    def test_v2_judge_scales_cells_before_observing_outputs(self):
        rows = make_v2_inputs(read_jsonl(build.HERE / "benchmark-songs-v2.jsonl"))
        selected = selected_prompts(rows, version=V2_VERSION, rubric_version=LEGACY_RUBRIC)
        self.assertEqual(len(selected), 270)
        self.assertEqual(selected, selected_prompts(list(reversed(rows)), version=V2_VERSION, rubric_version=LEGACY_RUBRIC))
        self.assertEqual({v for k, v in judged_counts(selected).items() if k.startswith("suggestions/")}, {15})
        self.assertEqual({v for k, v in judged_counts(selected).items() if k.startswith("rewrite_passage/")}, {30})
        with self.assertRaisesRegex(ValueError, "270"):
            selected_prompts(rows[:8], version=V2_VERSION, rubric_version=LEGACY_RUBRIC)

    def test_versions_cannot_share_even_interrupted_output(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            write_json(out / "inputs.json", [])
            with self.assertRaisesRegex(ValueError, "artifacts"):
                require_mode(out, V2_VERSION)
            write_json(out / "benchmark.json", {"version": V2_VERSION})
            with self.assertRaisesRegex(ValueError, "Cannot mix"):
                require_mode(out, FROZEN_VERSION)

    def test_v2_frozen_inputs_and_required_exclusion_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("2026-10-07/rhymeai-teacher-data-v3", "2026-10-08/rhymeai-colab-package-levels",
                         "2026-10-14/rhymeai-round2"):
                (root / name).mkdir(parents=True)
            dev = root / "2026-10-14/rhymeai-round2/dev-songs.jsonl"
            dev.write_text("")
            with patch.object(build, "ARTIFACTS", root):
                out = root / "run"
                manifest = freeze(out, "v2")
                frozen = json.loads((build.HERE / "frozen-v2.json").read_text())
                self.assertEqual(manifest["inputs_sha256"], frozen["inputs_sha256"])
                with patch("sys.argv", ["build.py", "--benchmark", "v2", "--out", str(root / "cli")]), contextlib.redirect_stdout(io.StringIO()):
                    runpy.run_path(str(build.HERE / "build.py"), run_name="__main__")
                self.assertEqual(sha256(root / "cli/inputs.json"), frozen["inputs_sha256"])
                paths = {r["path"] for r in json.loads((out / "overlap.json").read_text())["files"]}
                self.assertIn(str(build.HERE / "benchmark-songs.jsonl"), paths)
                self.assertIn(str(dev), paths)
                dev.write_text((build.HERE / "benchmark-songs-v2.jsonl").read_text())
                with self.assertRaisesRegex(ValueError, "contamination"):
                    freeze(root / "contaminated", "v2")
                dev.unlink()
                with self.assertRaises(FileNotFoundError):
                    freeze(root / "missing-exclusion", "v2")

    def test_versioned_margins_apply_to_bounds_and_seed_points(self):
        values = {key: {"delta": 0, "ci95": [0, 0]} for key in MARGINS}
        values["rewrite_word"] = {"delta": -.02, "ci95": [-.03, 0]}
        self.assertTrue(yield_pass(values, 0))
        margins = dict(MARGINS, rewrite_word=.01)
        self.assertFalse(yield_pass(values, 0, margins=margins))
        self.assertFalse(yield_pass(values, 0, bound=False, margins=margins))

    def test_uncalibrated_v2_rejects_candidate_before_creating_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "frozen-v2.json"
            write_json(manifest, {"version": V2_VERSION})
            out = root / "run"
            with patch("gate.run_gate.frozen_path", return_value=manifest), patch("sys.argv", [
                    "run_gate.py", "--benchmark", "v2", "--candidate", "unused.gguf", "--out", str(out)]):
                with self.assertRaises(SystemExit):
                    main()
            self.assertFalse(out.exists())

    @unittest.skipUnless(os.environ.get("RHYMEAI_PARITY_EVIDENCE"), "Requires real Kotlin exports for both versions")
    def test_real_kotlin_exports_match_every_frozen_prompt_hash(self):
        root = Path(os.environ["RHYMEAI_PARITY_EVIDENCE"])
        for directory, manifest in (("v1-parity", "frozen.json"), ("null-noise", "frozen-v2.json")):
            frozen = json.loads((build.HERE / manifest).read_text())
            out = root / directory
            self.assertEqual(sha256(out / "inputs.json"), frozen["inputs_sha256"])
            self.assertEqual(sha256(out / "prompts.json"), frozen["prompts_sha256"])
            prompts = json.loads((out / "prompts.json").read_text())
            self.assertEqual([{k:r[k] for k in ("id", "inputs_sha256", "prompt_sha256", "wrapped_prompt_sha256")}
                              for r in prompts], frozen["prompt_hashes"])
            parity = read_jsonl(out / "parity.jsonl")
            self.assertEqual(len(parity), frozen["prompts"])
            self.assertTrue(all(p["frozen_byte_parity"] and text_hash(p["prompt"]) == p["prompt_sha256"] for p in parity))


if __name__ == "__main__":
    unittest.main()
