import unittest

from teacher_data import BOUNDARY, END, START, parse_row, reject_reason, split_rows


class TeacherDataTests(unittest.TestCase):
    def row(self, context="first lyric", suffix="", task="rewrite_passage"):
        prompt = 'Lyrics context:\n"""\n' + context + '\n"""\n' + suffix
        return parse_row({"text": START + prompt + BOUNDARY + "a new lyric" + END, "task": task})

    def test_context_variants_stay_together(self):
        rows = [self.row(suffix=str(i)) for i in range(20)]
        splits = split_rows(rows)
        self.assertEqual(sum(bool(values) for values in splits.values()), 1)

    def test_shared_prompt_unions_otherwise_distinct_groups(self):
        a, b = self.row("song a"), self.row("song b")
        b["prompt_sha256"] = a["prompt_sha256"]
        c = self.row("song b", "another action")
        splits = split_rows([a, b, c])
        self.assertEqual(sum(bool(values) for values in splits.values()), 1)

    def test_control_marker_is_rejected(self):
        row = self.row()
        row["completion"] = "a lyric\n<|channel>thought"
        self.assertEqual(reject_reason(row), "control_marker")

    def test_copied_suggestion_is_rejected(self):
        row = self.row("first lyric", task="suggestions")
        row["completion"] = "first lyric\nsecond lyric\nthird lyric\nfourth lyric\nfifth lyric\nsixth lyric"
        self.assertEqual(reject_reason(row), "copied_lyric_line")

    def test_malformed_serialization_fails(self):
        with self.assertRaises(ValueError):
            parse_row({"text": "old wrapper", "task": "suggestions"})


if __name__ == "__main__":
    unittest.main()
