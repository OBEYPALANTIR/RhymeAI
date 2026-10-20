"""Teacher and eval outputs: an echoed model-turn opener is stripped, any
other turn/channel control token is rejected, in both prompt envelopes.

Run: python3 -m unittest discover -s finetune -p 'test_*.py'
"""

import os
import sys
import unittest

FINETUNE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if FINETUNE not in sys.path:
    sys.path.insert(0, FINETUNE)

from eval import cases, run_eval, scoring  # noqa: E402
from data import generate  # noqa: E402

GEMMA4_MARKERS = ("<|turn>", "<turn|>", "<|channel>", "<channel|>")


def rewrite_case():
    case = dict(next(c for c in cases.CASES if c["task"] == "rewrite_passage"))
    lines = [line for line in case["selection"].split("\n") if line.strip()]
    rewrite = "\n".join("Neon rivers carry me home tonight %d" % i for i in range(len(lines)))
    return case, rewrite


class ReplyClient:
    def __init__(self, raw):
        self.raw = raw

    def generate(self, user_prompt, seed=None):
        return self.raw


class ControlMarkerTests(unittest.TestCase):
    def test_echoed_gemma4_model_prefix_is_stripped(self):
        for raw in ("<|turn>model\nA brighter line tonight", "<|turn>model A brighter line tonight",
                    "<|turn>user\nhi<turn|>\n<|turn>model\nA brighter line tonight"):
            self.assertEqual(scoring.strip_model_output(raw), "A brighter line tonight")
            self.assertEqual(generate.clean_teacher_output(raw), "A brighter line tonight")

    def test_generator_stores_rewrite_without_the_echoed_prefix(self):
        case, rewrite = rewrite_case()
        record, reason = generate.generate_one(
            ReplyClient("<|turn>model\n" + rewrite), case, "1-0-0")
        self.assertEqual(reason, "accepted")
        self.assertEqual(record["completion"], rewrite)

    def test_gemma4_marker_mid_text_is_rejected(self):
        case, rewrite = rewrite_case()
        first, _, rest = rewrite.partition("\n")
        for marker in GEMMA4_MARKERS + ("<|think|>",):
            for raw in (first + marker + ("\n" + rest if rest else ""),
                        first + " " + marker + "thought" + ("\n" + rest if rest else ""),
                        first + "\n" + marker + ("\n" + rest if rest else "")):
                self.assertIn(marker, generate.clean_teacher_output(raw))
                self.assertIn("control_marker",
                              scoring.validate_rewrite_passage(raw, case["selection"])["violations"])
                record, reason = generate.generate_one(ReplyClient(raw), case, "1-0-0")
                self.assertEqual((record, reason), (None, "rejected_by_scorer"), raw)

    def test_leading_thought_channel_is_cut_and_stray_closers_are_rejected(self):
        case, rewrite = rewrite_case()
        for opener in ("<|channel>thought\n<channel|>", "<|channel>thought\nweighing rhymes<channel|>\n"):
            self.assertEqual(generate.clean_teacher_output(opener + rewrite), rewrite)
        first, _, rest = rewrite.partition("\n")
        if rest:
            raw = "<|channel>thought\n<channel|>" + first + "\n<channel|>" + rest
            self.assertIn("<channel|>", generate.clean_teacher_output(raw))
            record, reason = generate.generate_one(ReplyClient(raw), case, "1-0-0")
            self.assertEqual((record, reason), (None, "rejected_by_scorer"))

    def test_unterminated_thought_channel_is_explicitly_rejected(self):
        case, rewrite = rewrite_case()
        for raw in ("<|channel>thought", " \n<|channel>thought\n" + rewrite,
                    "<|channel>thought\n<|turn>model\n" + rewrite):
            with self.subTest(raw=raw):
                record, reason = generate.generate_one(ReplyClient(raw), case, "1-0-0")
                self.assertEqual((record, reason), (None, "unterminated_thought_channel"))

    def test_gemma4_marker_fails_every_validator(self):
        for marker in GEMMA4_MARKERS:
            lines = ["Line %s number %d" % (word, i) for i, word in
                     enumerate(("amber", "cobalt", "silver", "scarlet", "golden", "violet"))]
            lines[2] += marker
            suggestions = scoring.validate_suggestions("\n".join(lines), 6, "")
            self.assertIn((2, ["control_marker"]), suggestions["violations"])
            self.assertFalse(scoring.validate_single_word_rewrite("Glow" + marker, "shine")["passed"])
            self.assertFalse(scoring.validate_synonyms("gleam\nglow" + marker, "shine", 8)["passed"])

    def test_legacy_markers_behave_as_before(self):
        # Expected values are what origin/main produced before this change.
        self.assertEqual(scoring.strip_model_output("<start_of_turn>model\nGlow\n<end_of_turn>"), "Glow")
        self.assertEqual(scoring.strip_model_output("Line one<end_of_turn>\nleftover"), "Line one")
        self.assertEqual(scoring.strip_model_output("start_of_turn>model\nLine one"), "Line one")
        self.assertEqual(generate.clean_teacher_output("_response>\nLine one\n<br>\nLine two"),
                         "Line one\nLine two")
        self.assertEqual(generate.clean_teacher_output("Line one\n<start_of_turn>user\nLine two"),
                         "Line one\nLine two")
        self.assertEqual(generate.clean_teacher_output("<end_of_turn>model Line one"), "")
        for text in ("<start_of_turn>", "end_of_turn>", "_response>", "</start_of_turn>",
                     "model_response>"):
            self.assertTrue(scoring.CONTROL_MARKER_RE.search("A line " + text), text)
        for text in ("A plain lyric line", "Pipes | and <angles> alone", "x > y < z"):
            self.assertIsNone(scoring.CONTROL_MARKER_RE.search(text), text)

    def test_eval_scoring_rejects_gemma4_markers(self):
        case, rewrite = rewrite_case()
        prepared = run_eval.prepare_case(case)
        self.assertTrue(run_eval.score_case(prepared, rewrite)["format"]["passed"])
        self.assertTrue(run_eval.score_case(prepared, "<|turn>model\n" + rewrite)["format"]["passed"])
        self.assertFalse(run_eval.score_case(prepared, rewrite + "<turn|>")["format"]["passed"])


if __name__ == "__main__":
    unittest.main()
