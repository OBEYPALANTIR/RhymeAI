"""Single-word rewrite and synonym validators reject spellings the apps drop:
AIService.isKnownSingleWord (Android) / LexicalWordValidator.isKnownSpelling
(iOS) require the lowercased word to be a CMU dictionary key.

Run: python3 -B -m unittest discover -s finetune/eval -p 'test_*.py'
"""

import os
import sys
import unittest

FINETUNE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if FINETUNE not in sys.path:
    sys.path.insert(0, FINETUNE)

from eval import scoring  # noqa: E402


class KnownWordTests(unittest.TestCase):
    def test_curly_apostrophes_normalize_like_the_apps(self):
        # LyricTokenizer / ProsodyAnalyzer.normalizeWord treat U+2019 and U+02BC as "'".
        self.assertEqual(scoring.normalize_word("We\u2019re"), "we're")
        self.assertEqual(scoring.normalize_word("don\u02BCt"), "don't")
        self.assertEqual(scoring.WORD_PATTERN.findall("we\u2019re done"), ["we\u2019re", "done"])

    def test_is_known_single_word_mirrors_app_rule(self):
        self.assertTrue(scoring.is_known_single_word("shine"))
        self.assertTrue(scoring.is_known_single_word("Glow"))  # key is the lowercase spelling
        self.assertFalse(scoring.is_known_single_word("g-l-e-a-m"))  # key != normalizeWord
        self.assertFalse(scoring.is_known_single_word("promisee"))  # not in the dictionary
        self.assertFalse(scoring.is_known_single_word("two words"))
        self.assertFalse(scoring.is_known_single_word("a" * 33))

    def test_single_word_rewrite_flags_unknown_word(self):
        self.assertTrue(scoring.validate_single_word_rewrite("shine", "glow", ["gleam"])["passed"])
        result = scoring.validate_single_word_rewrite("g-l-e-a-m", "glow", ["gleam"])
        self.assertIn("unknown_word", result["violations"])
        self.assertIn("in_rejected_list", result["violations"])
        self.assertNotIn(
            "unknown_word",
            scoring.validate_single_word_rewrite("two words", "glow")["violations"],
        )

    def test_synonyms_flag_unknown_words_per_line(self):
        result = scoring.validate_synonyms("pledge\nvowee\npromisee", "promise", 5)
        self.assertFalse(result["passed"])
        self.assertEqual(
            [(index, violations) for index, violations in result["violations"]],
            [(1, ["unknown_word"]), (2, ["unknown_word"])],
        )
        self.assertTrue(scoring.validate_synonyms("pledge\nvow\nOath", "promise", 5)["passed"])


if __name__ == "__main__":
    unittest.main()
