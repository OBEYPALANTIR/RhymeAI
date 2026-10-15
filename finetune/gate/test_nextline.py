import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from .build import HERE, V2_VERSION, make_v2_inputs, read_jsonl, text_hash, write_json, write_jsonl
from .judge import (JUDGE_PROMPT, LEGACY_RUBRIC, NEXTLINE_PROMPT, NEXTLINE_RUBRIC,
                    codex_batch, judge, recorded_rubric, selected_prompts)
from .report import report, summarize
from .test_resume import judge_fixture


def judgments(task, count, outcome):
    return [dict(id=f"{task}-{i}", song_id=f"song-{i % 60}", task=task,
                 level=("Simple", "Moderate", "Complex")[i % 3],
                 rhyme_type=("PERFECT", "NEAR", "SLANT", "NEW_SOUND")[i % 4],
                 outcome=outcome) for i in range(count)]


class NextLineTest(unittest.TestCase):
    def test_passage_votes_cannot_change_nextline_g3_or_seed_agreement(self):
        suggestions = judgments("suggestions", 180, "candidate")
        expected = summarize([], suggestions)
        for outcome in ("incumbent", "candidate", "tie", "invalid"):
            observed = summarize([], suggestions + judgments("rewrite_passage", 900, outcome))
            self.assertEqual(observed, expected)
        self.assertTrue(expected["gates"]["G3"])
        self.assertTrue(expected["consistent"]["G3"])

    def test_passage_win_cannot_rescue_flat_suggestions(self):
        rows = judgments("suggestions", 180, "tie") + judgments("rewrite_passage", 90, "candidate")
        nextline = summarize([], rows)
        legacy = summarize([], rows, rubric_version=LEGACY_RUBRIC)
        self.assertTrue(legacy["gates"]["G3"])
        self.assertFalse(nextline["gates"]["G3"])
        self.assertFalse(nextline["consistent"]["G3"])
        self.assertEqual(nextline["preference"]["all"]["net_preference"]["ci95"], [0, 0])

    def test_each_kind_of_losing_stratum_blocks_an_overall_win(self):
        for axis, value in (("level", "Complex"), ("rhyme_type", "PERFECT")):
            with self.subTest(axis=axis):
                rows = judgments("suggestions", 180, "candidate")
                for row in rows:
                    if row[axis] == value:
                        row["outcome"] = "incumbent"
                result = summarize([], rows)
                self.assertGreater(result["preference"]["all"]["net_preference"]["ci95"][0], 0)
                self.assertLess(result["preference"][f"{axis}:{value}"]["net_preference"]["ci95"][1], 0)
                self.assertFalse(result["gates"]["G3"])

    def test_v2_selects_the_same_suggestions_without_passages(self):
        rows = make_v2_inputs(read_jsonl(HERE / "benchmark-songs-v2.jsonl"))
        old = selected_prompts(rows, version=V2_VERSION, rubric_version=LEGACY_RUBRIC)
        new = selected_prompts(rows, version=V2_VERSION)
        self.assertEqual(new, [r for r in old if r["task"] == "suggestions"])
        self.assertEqual(len(new), 180)

    def test_rubric_version_and_sha_must_match_and_old_hash_keeps_identity(self):
        old = {"rubric_sha256": text_hash(JUDGE_PROMPT)}
        self.assertEqual(recorded_rubric(old), LEGACY_RUBRIC)
        self.assertEqual(recorded_rubric(dict(old, rubric_version=LEGACY_RUBRIC)), LEGACY_RUBRIC)
        new = {"rubric_version": NEXTLINE_RUBRIC, "rubric_sha256": text_hash(NEXTLINE_PROMPT)}
        self.assertEqual(recorded_rubric(new), NEXTLINE_RUBRIC)
        for invalid in ({}, dict(new, rubric_sha256=old["rubric_sha256"]),
                        dict(old, rubric_version="future-v2"), {"rubric_sha256": new["rubric_sha256"]}):
            with self.assertRaisesRegex(ValueError, "rubric"):
                recorded_rubric(invalid)

    def test_cached_legacy_batch_cannot_resume_under_nextline_rubric(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            pairs, binding = judge_fixture(out)
            pairs[0]["task"] = "suggestions"
            write_json(out / "batch.binding.json", binding)
            original = (out / "batch.binding.json").read_bytes()
            with self.assertRaisesRegex(ValueError, "binding mismatch"):
                codex_batch(out, pairs, False, "batch")
            self.assertEqual((out / "batch.binding.json").read_bytes(), original)
            pairs[0]["task"] = "rewrite_passage"
            with self.assertRaisesRegex(ValueError, "suggestion pairs only"):
                codex_batch(out, pairs, False, "batch")

    def test_judging_cannot_overwrite_a_historical_rubric(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            write_json(out / "judge-provenance.json", {"rubric_sha256": text_hash(JUDGE_PROMPT)})
            write_jsonl(out / "pairs.jsonl", [{"historical": True}])
            before = {p.name: p.read_bytes() for p in out.iterdir()}
            with self.assertRaisesRegex(ValueError, "Historical rubric is immutable"):
                judge(out)
            self.assertEqual({p.name: p.read_bytes() for p in out.iterdir()}, before)

    @unittest.skipUnless(os.environ.get("RHYMEAI_LEGACY_RUNS"), "Requires saved v1/v2 run directories")
    def test_recorded_v1_v2_summaries_rescore_unchanged_on_copies(self):
        versions = set()
        for source in map(Path, os.environ["RHYMEAI_LEGACY_RUNS"].split(os.pathsep)):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                old = json.loads((source / "summary.json").read_text())
                versions.add(old["benchmark_version"])
                self.assertEqual(recorded_rubric(old["judge"]), LEGACY_RUBRIC)
                out = Path(directory) / "copy"
                shutil.copytree(source, out)
                report(out)
                self.assertEqual(json.loads((out / "summary.json").read_text()), old)
        self.assertEqual(versions, {"rhymeai-gate-v1", "rhymeai-gate-v2"})


if __name__ == "__main__":
    unittest.main()
