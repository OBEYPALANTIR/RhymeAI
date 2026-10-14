import json
import tempfile
import unittest
from pathlib import Path

from .build import grams, overlapping_lines, pool_lines
from .cxlib import grade_shown_lines
from .metrics import not_worse, paired, preference, preference_pass, template_pairs, yield_pass
from .report import gate_verdict


class OverlapTest(unittest.TestCase):
    def test_normalization_and_decoded_line_boundaries(self):
        songs = [{"id": "one", "lines": ["We carry seven silver cups across the frozen river"]}]
        self.assertEqual(overlapping_lines(songs, ["WE carry seven silver cups, across the frozen river!"]), [("one", 1)])
        self.assertEqual(overlapping_lines(songs, ["We carry seven silver cups across the", "frozen river"]), [])
        self.assertFalse(grams("one two three four five six seven"))

    def test_nested_json_and_python_literals_are_scanned(self):
        phrase = "eight little tokens can hide in a nested dictionary"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "train.jsonl"
            path.write_text(json.dumps({"messages": [{"content": "prefix\n" + phrase}]}) + "\n")
            self.assertIn(phrase, list(pool_lines(path)))
            path = Path(directory) / "seed.py"
            path.write_text('SONGS = {"one": ' + repr(phrase) + '}\n')
            self.assertEqual(list(pool_lines(path)), ["one", phrase])


class MetricTest(unittest.TestCase):
    def test_level_rules_keep_every_shown_line_without_legacy_response_rescoring(self):
        lines = ["Copper whistles settle softly into silver conversation", "Copper whistles settle slowly into our silver conversation"]
        grades = grade_shown_lines(lines, "Complex", ["conversation"])
        self.assertEqual([g["line"] for g in grades], lines)
        self.assertEqual([g["pass_level"] for g in grades], [False, True])

    def test_template_repetition_ignores_function_words_but_requires_three_tokens(self):
        self.assertEqual(template_pairs(["I carry broken clocks home", "We carry the broken clocks away", "Copper birds settle slowly"]), (1, 3))
        self.assertEqual(template_pairs(["I wait", "We wait"]), (0, 1))
        self.assertEqual(template_pairs([]), (0, 0))

    def test_equal_paired_ratios_have_exact_zero_interval(self):
        rows = [{"song_id": str(i), "candidate": {"n": i + 1, "d": 8}, "incumbent": {"n": i + 1, "d": 8}} for i in range(4)]
        result = paired(rows, "n", "d")
        self.assertEqual(result["delta"], 0)
        self.assertEqual(result["ci95"], [0, 0])
        self.assertTrue(not_worse(result, 0))
        self.assertTrue(not_worse(result, 0, False))

    def test_ratio_of_sums_and_song_clustering(self):
        rows = [{"song_id": "same", "candidate": {"n": 1, "d": 2}, "incumbent": {"n": 0, "d": 2}},
                {"song_id": "same", "candidate": {"n": 0, "d": 8}, "incumbent": {"n": 0, "d": 8}}]
        result = paired(rows, "n", "d")
        self.assertEqual(result["candidate"], .1)
        self.assertEqual(result["song_clusters"], 1)
        self.assertEqual(result["ci95"], [.1, .1])
        self.assertIsNone(paired([], "n", "d"))
        self.assertIsNone(paired([{"song_id": "empty", "candidate": {"n": 0, "d": 0}, "incumbent": {"n": 0, "d": 0}}], "n", "d"))


class VerdictTest(unittest.TestCase):
    def metric(self, lo=0, hi=0, delta=0):
        return {"ci95": [lo, hi], "delta": delta}

    def test_yield_margins_and_errors(self):
        metrics = {k: self.metric() for k in ("full_six", "retry", "rewrite_passage", "rewrite_word", "synonyms")}
        metrics["retry"] = self.metric(-.01, .065)
        metrics["rewrite_passage"] = self.metric(-.085, .01)
        metrics["rewrite_word"] = self.metric(-.035, .01)
        metrics["synonyms"] = self.metric(-.01, 0)
        self.assertTrue(yield_pass(metrics, 0))
        self.assertFalse(yield_pass(metrics, 1))
        for key, past in (("rewrite_passage", -.0851), ("rewrite_word", -.0351), ("synonyms", -.0101), ("full_six", -.0101)):
            saved, metrics[key] = metrics[key], self.metric(past, .01)
            self.assertFalse(yield_pass(metrics, 0), key)
            metrics[key] = saved
        metrics["retry"] = self.metric(0, .0651)
        self.assertFalse(yield_pass(metrics, 0))
        # Point-estimate mode (G6 per seed) ignores interval width but keeps the margins.
        wide = {k: self.metric(-.5, .5, 0) for k in metrics}
        self.assertTrue(yield_pass(wide, 0, bound=False))
        wide["rewrite_word"] = self.metric(-.5, .5, -.036)
        self.assertFalse(yield_pass(wide, 0, bound=False))
        wide["rewrite_word"] = self.metric(-.5, .5, 0)
        wide["retry"] = self.metric(-.5, .5, .066)
        self.assertFalse(yield_pass(wide, 0, bound=False))

    def test_level_and_repetition_margins_in_both_modes(self):
        self.assertTrue(not_worse(self.metric(-.055, .01), .055))
        self.assertFalse(not_worse(self.metric(-.0551, .01), .055))
        self.assertTrue(not_worse(self.metric(-.01, .0025), .0025, False))
        self.assertFalse(not_worse(self.metric(-.01, .0026), .0025, False))
        self.assertTrue(not_worse(self.metric(-.5, .5, -.055), .055, bound=False))
        self.assertFalse(not_worse(self.metric(-.5, .5, -.056), .055, bound=False))
        self.assertTrue(not_worse(self.metric(-.5, .5, .0025), .0025, False, bound=False))
        self.assertFalse(not_worse(self.metric(-.5, .5, .0026), .0025, False, bound=False))
        self.assertFalse(not_worse(None, .055))

    def test_g6_needs_every_seed_and_never_rescues_pooled_g3(self):
        agree = {"G2": True, "G3": True, "G4": True, "G5": True}
        pooled = {"gates": {"G2": True, "G3": True, "G4": True, "G5": True}}
        seeds = {s: {"consistent": dict(agree)} for s in ("7000", "7001", "7002")}
        self.assertEqual(gate_verdict(True, {"pooled": pooled, **seeds})[1], "PASS")
        # One seed with zero or negative net preference fails G6 and the verdict.
        seeds["7001"]["consistent"]["G3"] = False
        gates, verdict = gate_verdict(True, {"pooled": pooled, **seeds})
        self.assertFalse(gates["G6"])
        self.assertEqual(verdict, "FAIL")
        # G6 agreement cannot rescue a pooled G3 failure (the disjoint-seed null's shape).
        seeds["7001"]["consistent"]["G3"] = True
        pooled["gates"]["G3"] = False
        gates, verdict = gate_verdict(True, {"pooled": pooled, **seeds})
        self.assertTrue(gates["G6"])
        self.assertEqual(verdict, "FAIL")
        self.assertEqual(gate_verdict(True, {"pooled": {"gates": dict(agree)}, **seeds}, dev=True)[1], "DEV")

    def test_null_does_not_win_and_stratum_loss_blocks_overall_win(self):
        ties = preference([{"song_id": str(i), "outcome": "tie"} for i in range(150)])
        self.assertEqual(ties["sign_p"], 1)
        self.assertFalse(preference_pass({"all": ties}, 150))
        win = preference([{"song_id": str(i), "outcome": "candidate"} for i in range(150)])
        self.assertTrue(preference_pass({"all": win}, 150))
        self.assertFalse(preference_pass({"all": win}, 149))
        loss = preference([{"song_id": str(i), "outcome": "incumbent"} for i in range(10)])
        self.assertFalse(preference_pass({"all": win, "level:Complex": loss}, 150))
        self.assertFalse(not_worse(self.metric(-.056, .01), .055))
        self.assertFalse(not_worse(self.metric(-.01, .0026), .0025, False))

    def test_repeated_songs_cannot_manufacture_a_significant_win(self):
        # 120 wins from one song vs 60 losses from another: row sign p is tiny, but two songs carry no evidence.
        rows = ([{"song_id": "a", "outcome": "candidate"}] * 120 + [{"song_id": "b", "outcome": "incumbent"}] * 60)
        clustered = preference(rows)
        self.assertLess(clustered["sign_p"], .001)
        self.assertFalse(preference_pass({"all": clustered}, 150))
        # The same imbalance spread over many songs is real evidence.
        spread = preference([{"song_id": f"w{i}", "outcome": "candidate"} for i in range(120)]
                            + [{"song_id": f"l{i}", "outcome": "incumbent"} for i in range(60)])
        self.assertTrue(preference_pass({"all": spread}, 150))


if __name__ == "__main__":
    unittest.main()
