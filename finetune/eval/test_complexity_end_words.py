"""Level-aware allowed end-word lists and the numeric Simple/Complex hints.

The list rule (scoring.level_end_words) and the hint strings
(prompts.RHYME_COMPLEXITIES) mirror Android RhymeConstraint.levelEndWords /
RhymeComplexity.promptHint and iOS RhymeConstraint.levelEndWords /
RhymeComplexity.promptHint; the shared fixture pins the Android parity.

Run: python3 -B -m unittest discover -s finetune/eval -p 'test_*.py'
"""

import copy
import json
import os
import sys
import unittest

FINETUNE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if FINETUNE not in sys.path:
    sys.path.insert(0, FINETUNE)

from eval import cases, complexity_end_words_fixture, prompts, run_eval, scoring  # noqa: E402

SIMPLE_HINT = (
    "Each line must be 4 to 7 plain, everyday words. Prefer one-syllable end words. No wordplay."
)
COMPLEX_HINT = (
    "Each line must be 8 to 12 words. End each line on a word of two or more syllables, or put "
    "an internal rhyme inside the line. Use vivid, specific, less common words and double meanings."
)
MODERATE_HINT = (
    "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear "
    "rather than clever."
)

# Perfect rhymes of "road": frequency order is the dictionary (insertion) order
# because none of these words are in the frequency list. "episode" (EH1 P AH0 S
# OW2 D) comes from the multisyllabic pool, after every exact match.
SMALL_DICTIONARY = scoring.PronunciationDictionary({
    "road": [["R", "OW1", "D"]],
    "explode": [["IH0", "K", "S", "P", "L", "OW1", "D"]],
    "glowed": [["G", "L", "OW1", "D"]],
    "overload": [["OW2", "V", "ER0", "L", "OW1", "D"]],
    "showed": [["SH", "OW1", "D"]],
    "bestowed": [["B", "IH0", "S", "T", "OW1", "D"]],
    "rode": [["R", "OW1", "D"]],
    "code": [["K", "OW1", "D"]],
    "load": [["L", "OW1", "D"]],
    "owed": [["OW1", "D"]],
    "towed": [["T", "OW1", "D"]],
    "episode": [["EH1", "P", "AH0", "S", "OW2", "D"]],
})
EMPTY_FREQUENCY = scoring.WordFrequency({})


def small_list(complexity, limit=12):
    matches = scoring.find_rhymes("road", dictionary=SMALL_DICTIONARY, word_frequency=EMPTY_FREQUENCY)
    ordered = [w for w in matches.perfect + matches.multi if w != "road"]
    return scoring.level_end_words(ordered, complexity, limit, dictionary=SMALL_DICTIONARY)


class LevelEndWordsTests(unittest.TestCase):
    def test_moderate_is_the_frequency_order(self):
        self.assertEqual(
            ["explode", "glowed", "overload", "showed", "bestowed", "rode", "code", "load", "owed", "towed", "episode"],
            small_list("MODERATE"),
        )

    def test_complex_puts_two_or_more_syllables_first_stably(self):
        self.assertEqual(
            ["explode", "overload", "bestowed", "episode", "glowed", "showed", "rode", "code", "load", "owed", "towed"],
            small_list("COMPLEX"),
        )
        self.assertEqual(["explode", "overload", "bestowed", "episode"], small_list("COMPLEX", limit=4))
        self.assertEqual(["explode", "overload", "bestowed", "episode", "glowed"], small_list("COMPLEX", limit=5))

    def test_simple_keeps_one_syllable_words_only(self):
        self.assertEqual(
            ["glowed", "showed", "rode", "code", "load", "owed", "towed"], small_list("SIMPLE")
        )

    def test_simple_falls_back_to_the_remaining_words_below_six(self):
        ordered = ["explode", "glowed", "overload", "showed", "bestowed"]
        self.assertEqual(
            ["glowed", "showed", "explode", "overload", "bestowed"],
            scoring.level_end_words(ordered, "SIMPLE", 12, dictionary=SMALL_DICTIONARY),
        )
        self.assertEqual(
            ["glowed", "showed", "explode"],
            scoring.level_end_words(ordered, "SIMPLE", 3, dictionary=SMALL_DICTIONARY),
        )
        self.assertEqual(6, scoring.SIMPLE_MIN_MONOSYLLABLES)

    def test_unknown_level_is_rejected(self):
        with self.assertRaises(ValueError):
            scoring.level_end_words(["glowed"], "EXTREME", 12, dictionary=SMALL_DICTIONARY)

    def test_ordered_candidates_is_the_pool_before_the_level_cut(self):
        ordered = scoring.ordered_candidates("road", "PERFECT", dictionary=SMALL_DICTIONARY)
        self.assertEqual(11, len(ordered))
        self.assertNotIn("road", ordered)
        self.assertEqual(
            scoring.level_end_words(ordered, "COMPLEX", 4, dictionary=SMALL_DICTIONARY),
            scoring.candidate_end_words("road", "PERFECT", limit=4, dictionary=SMALL_DICTIONARY, complexity="COMPLEX"),
        )
        self.assertEqual(12, scoring.CANDIDATE_LIMIT)

    def test_candidate_end_words_default_is_moderate(self):
        self.assertEqual(
            scoring.candidate_end_words("home", "PERFECT"),
            scoring.candidate_end_words("home", "PERFECT", complexity="MODERATE"),
        )


class SharedFixtureTests(unittest.TestCase):
    def test_fixture_matches_the_builder(self):
        with open(complexity_end_words_fixture.FIXTURE_PATH, encoding="utf-8") as handle:
            fixture = json.load(handle)
        self.assertEqual(complexity_end_words_fixture.build_fixture(), fixture)
        self.assertEqual(33, len(fixture["cases"]))
        for case in fixture["cases"]:
            self.assertEqual(
                case["expected"],
                scoring.candidate_end_words(
                    case["anchor"], case["rhymeType"], limit=fixture["limit"], complexity=case["complexity"]
                ),
                case,
            )

    def test_fixture_covers_every_rule_branch(self):
        fixture = complexity_end_words_fixture.build_fixture()
        by_key = {(c["anchor"], c["complexity"]): c["expected"] for c in fixture["cases"]}
        syllables = scoring.syllable_count_word
        # Complex: every anchor with 2+-syllable rhymes lists them first.
        for anchor in ("home", "night", "road", "alone", "glow", "time"):
            words = by_key[(anchor, "COMPLEX")]
            self.assertTrue(all(syllables(w) >= 2 for w in words), (anchor, words))
            self.assertEqual(
                [w for w in by_key[(anchor, "MODERATE")] if syllables(w) >= 2],
                [w for w in words if w in by_key[(anchor, "MODERATE")]],
                "Complex keeps the frequency order within the 2+-syllable group",
            )
            self.assertTrue(all(syllables(w) == 1 for w in by_key[(anchor, "SIMPLE")]), anchor)
        # Simple fallback: fewer than six one-syllable rhymes, then the rest in order.
        for anchor in ("world", "love"):
            words = by_key[(anchor, "SIMPLE")]
            mono = [w for w in words if syllables(w) == 1]
            self.assertTrue(0 < len(mono) < 6, (anchor, words))
            self.assertEqual(mono, words[: len(mono)])
            self.assertEqual(12, len(words))
        # All-multisyllable anchors: identical lists at every level.
        for anchor in ("river", "arrival", "surrender"):
            self.assertEqual(by_key[(anchor, "MODERATE")], by_key[(anchor, "SIMPLE")], anchor)
            self.assertEqual(by_key[(anchor, "MODERATE")], by_key[(anchor, "COMPLEX")], anchor)
        self.assertLess(len(by_key[("arrival", "SIMPLE")]), 6)


class HintAndPromptTests(unittest.TestCase):
    def test_hints_are_the_tested_wording(self):
        self.assertEqual(("Simple", SIMPLE_HINT), prompts.RHYME_COMPLEXITIES["SIMPLE"])
        self.assertEqual(("Moderate", MODERATE_HINT), prompts.RHYME_COMPLEXITIES["MODERATE"])
        self.assertEqual(("Complex", COMPLEX_HINT), prompts.RHYME_COMPLEXITIES["COMPLEX"])

    def _suggestion_case(self):
        return next(
            c for c in cases.CASES
            if c["task"] == "suggestions" and c["target_rhyme_line"] and c["rhyme_type"] == "PERFECT"
        )

    def test_level_reaches_the_prompt_line_and_the_list(self):
        for level, hint in (("SIMPLE", SIMPLE_HINT), ("MODERATE", MODERATE_HINT), ("COMPLEX", COMPLEX_HINT)):
            case = copy.deepcopy(self._suggestion_case())
            case["complexity"] = level
            prepared = run_eval.prepare_case(case)
            prompt = prepared["user_prompt"]
            label = prompts.RHYME_COMPLEXITIES[level][0]
            self.assertIn("\nComplexity: %s. %s\n" % (label, hint), prompt)
            constraint = prepared["constraint"]
            self.assertIsNotNone(constraint)
            expected = scoring.candidate_end_words(constraint.target_word, "PERFECT", complexity=level)
            self.assertEqual(expected, list(constraint.candidate_words))
            self.assertIn(
                "End each line with one of these rhyming words: %s (choose the most natural fit)."
                % ", ".join(expected),
                prompt,
            )

    def _prompt_for(self, anchor, level, chorus=None):
        target = "Everything we said about %s" % anchor
        lyrics = "[Verse]\n" + target
        constraint = prompts.suggestion_rhyme_constraint(target, "PERFECT", complexity=level)
        self.assertIsNotNone(constraint, anchor)
        prompt = prompts.build_suggestions_prompt(
            theme="", lyrics=lyrics, target_rhyme_line=target, rhyme_type="PERFECT", rhyme_scheme="AABB",
            current_letter="A", current_section="VERSE", complexity=level, use_whole_song_context=True,
            constraint=constraint,
        )
        return list(constraint.candidate_words), prompt

    def test_simple_fallback_prompts_never_contradict_their_list(self):
        """Anchors whose Simple list must carry longer words: the hint only prefers
        one-syllable endings and the end-word rule matches the list size."""
        label, hint = prompts.RHYME_COMPLEXITIES["SIMPLE"]
        for anchor, expect_mono in (("arrival", 0), ("river", 0), ("love", 4), ("world", 5)):
            words, prompt = self._prompt_for(anchor, "SIMPLE")
            self.assertEqual(expect_mono, sum(1 for w in words if scoring.syllable_count_word(w) == 1), (anchor, words))
            self.assertTrue(any(scoring.syllable_count_word(w) >= 2 for w in words), anchor)
            self.assertIn("\nComplexity: %s. %s\n" % (label, hint), prompt)
            self.assertNotIn("one-syllable word.", prompt)
            self.assertIn(
                "End each line with one of these rhyming words: %s (choose the most natural fit)." % ", ".join(words),
                prompt,
            )
            self.assertIn(prompts.local_end_word_rule(words), prompt)
            if anchor == "arrival":
                self.assertLess(len(words), 6)
                self.assertIn("The allowed list has fewer than six words, so end words may repeat", prompt)
            else:
                self.assertGreaterEqual(len(words), 6)
                self.assertIn("- End each line on a different word from the allowed list.", prompt)

    def test_road_prompt_is_consistent_at_every_level(self):
        for level in ("SIMPLE", "MODERATE", "COMPLEX"):
            words, prompt = self._prompt_for("road", level)
            label, hint = prompts.RHYME_COMPLEXITIES[level]
            self.assertEqual(12, len(words), level)
            self.assertIn("\nComplexity: %s. %s\n" % (label, hint), prompt)
            self.assertIn("- End each line on a different word from the allowed list.", prompt)
            self.assertIn(", ".join(words) + " (choose the most natural fit).", prompt)
            syllables = [scoring.syllable_count_word(w) for w in words]
            if level == "COMPLEX":
                self.assertTrue(all(n >= 2 for n in syllables), words)
            elif level == "SIMPLE":
                self.assertTrue(all(n == 1 for n in syllables), words)

    def test_repeated_chorus_hook_is_promoted_at_every_level(self):
        lyrics = (
            "[Chorus]\nI'm breaking through the code\nNo one knows the way I rode\n\n"
            "[Chorus]\nYellow lights on a midnight road"
        )
        refs = prompts.parse_section_map(lyrics)
        second = next(r for r in refs if r.type == "CHORUS" and r.ordinal == 2)
        hooks = prompts.first_chorus_end_words(lyrics)
        self.assertEqual(["code", "rode"], hooks)
        target = "Yellow lights on a midnight road"
        self.assertTrue(all(scoring.is_perfect_rhyme(w, "road") for w in hooks))
        # Complex pushes the one-syllable hooks past the 12-word cut; they must still lead.
        self.assertNotIn("code", scoring.candidate_end_words("road", "PERFECT", complexity="COMPLEX"))
        for level in ("SIMPLE", "MODERATE", "COMPLEX"):
            constraint = prompts.suggestion_rhyme_constraint(
                target, "PERFECT", section_ref=second, chorus_end_words=hooks, complexity=level
            )
            words = list(constraint.candidate_words)
            self.assertEqual(["code", "rode"], words[:2], level)
            self.assertEqual(scoring.CANDIDATE_LIMIT, len(words), level)
            self.assertEqual(len(set(words)), len(words), level)
            level_list = scoring.candidate_end_words("road", "PERFECT", complexity=level)
            self.assertEqual([w for w in level_list if w not in hooks][:10], words[2:], level)
        # A first-chorus word that does not rhyme with the target, or is the target
        # itself, is not promoted.
        constraint = prompts.suggestion_rhyme_constraint(
            target, "PERFECT", section_ref=second, chorus_end_words=["spark", "road", "code"], complexity="COMPLEX"
        )
        self.assertEqual("code", constraint.candidate_words[0])
        self.assertNotIn("spark", constraint.candidate_words)
        self.assertNotIn("road", constraint.candidate_words)

    def test_hook_promotion_verifies_the_requested_relation(self):
        """A perfect-rhyme hook is not promoted into a Near prompt (Android checks
        rhymeRelation == rhymeType); a near hook is; Slant promotes nothing because
        the eval cannot classify slant."""
        lyrics = (
            "[Chorus]\nI'm breaking through the code\n\n"
            "[Chorus]\nYellow lights on a midnight road"
        )
        refs = prompts.parse_section_map(lyrics)
        second = next(r for r in refs if r.type == "CHORUS" and r.ordinal == 2)
        target = "Yellow lights on a midnight road"
        near_pool = scoring.find_rhymes("road").near
        self.assertTrue(near_pool)
        near_hook = near_pool[0]
        self.assertFalse(scoring.is_perfect_rhyme(near_hook, "road"))
        near = prompts.suggestion_rhyme_constraint(
            target, "NEAR", section_ref=second, chorus_end_words=["code", near_hook], complexity="MODERATE"
        )
        plain_near = list(prompts.suggestion_rhyme_constraint(target, "NEAR", complexity="MODERATE").candidate_words)
        # Only the near hook is promoted; "code" keeps whatever place the Near list gives it.
        self.assertEqual([near_hook] + [w for w in plain_near if w != near_hook][:scoring.CANDIDATE_LIMIT - 1],
                         list(near.candidate_words))
        slant = prompts.suggestion_rhyme_constraint(
            target, "SLANT", section_ref=second, chorus_end_words=["code", near_hook], complexity="MODERATE"
        )
        plain = prompts.suggestion_rhyme_constraint(target, "SLANT", complexity="MODERATE")
        self.assertEqual(list(plain.candidate_words), list(slant.candidate_words))

    def test_hook_promotion_checks_the_whole_near_pool(self):
        """A near hook ranked past find_rhymes' default 30-word cap is still
        promoted, as Android's direct rhymeRelation check would promote it."""
        lyrics = (
            "[Chorus]\nI'm breaking through the code\n\n"
            "[Chorus]\nYellow lights on a midnight road"
        )
        refs = prompts.parse_section_map(lyrics)
        second = next(r for r in refs if r.type == "CHORUS" and r.ordinal == 2)
        target = "Yellow lights on a midnight road"
        capped = scoring.find_rhymes("road").near
        full = scoring.find_rhymes("road", near_limit=None).near
        late_hook = next(w for w in full if w not in capped)
        constraint = prompts.suggestion_rhyme_constraint(
            target, "NEAR", section_ref=second, chorus_end_words=[late_hook], complexity="MODERATE"
        )
        self.assertEqual(late_hook, constraint.candidate_words[0])

    def test_levels_build_different_lists_for_a_mixed_anchor(self):
        constraints = {
            level: prompts.suggestion_rhyme_constraint("I keep the porch light on at home", "PERFECT", complexity=level)
            for level in ("SIMPLE", "MODERATE", "COMPLEX")
        }
        words = {level: list(c.candidate_words) for level, c in constraints.items()}
        self.assertNotEqual(words["SIMPLE"], words["MODERATE"])
        self.assertNotEqual(words["COMPLEX"], words["MODERATE"])
        self.assertTrue(all(scoring.syllable_count_word(w) >= 2 for w in words["COMPLEX"]))
        self.assertTrue(all(scoring.syllable_count_word(w) == 1 for w in words["SIMPLE"]))
        self.assertEqual(
            words["MODERATE"],
            list(prompts.suggestion_rhyme_constraint("I keep the porch light on at home", "PERFECT").candidate_words),
            "the default level is Moderate",
        )


if __name__ == "__main__":
    unittest.main()
