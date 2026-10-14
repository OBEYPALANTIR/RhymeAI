"""Unchanged grading definitions extracted from the 2026-10-08 levels package.

Source cxlib.py SHA-256: 560be4c71a2bda05e499e8924913be675888197c1d667107312b6e85a659e824
Only the grading dependency closure is retained; training/server helpers are omitted.
"""

from pathlib import Path
from eval import scoring
from . import phonetics as g

REPO = Path(__file__).resolve().parents[2]
DICT_PATH = REPO / "shared/pronunciation/cmudict-rhymeai.tsv"
FREQ_PATH = REPO / "shared/pronunciation/word-frequency.txt"

LEVEL_WORDS = {"Simple": (4, 7), "Moderate": (5, 9), "Complex": (8, 12)}


COMMON_WORD_RANK = 3000


class Sounds:
    """filter_teacher.Sounds, verbatim apart from the module handles."""

    def __init__(self, g_mod, dictionary, frequency_path, common_rank=COMMON_WORD_RANK):
        self.g = g_mod
        self.SC = scoring
        self.dictionary = dictionary
        words = [w.strip() for w in Path(frequency_path).read_text().splitlines()
                 if w.strip() and not w.startswith("#")]
        self.common = set(words[:common_rank])
        self.common_rank = common_rank

    def syllables(self, word):
        return self.SC.syllable_count_word(word)

    def tail_keys(self, word):
        if not word or word in self.g.STOPWORDS or word in self.g.FUNCTION_WORDS:
            return set()
        keys = set()
        for phones in self.dictionary.get(word, []):
            keys.update(self.g.rhyme_keys_for_phones(phones, 1))
        return keys

    def internal_rhyme(self, tokens):
        keys = [self.tail_keys(t) for t in tokens]
        for i in range(len(tokens)):
            if not keys[i]:
                continue
            for j in range(i + 2, len(tokens)):
                if keys[i] & keys[j] and tokens[i] != tokens[j] \
                        and not self.g.is_inflection(tokens[i], tokens[j]) \
                        and not self.g.is_inflection(tokens[j], tokens[i]):
                    return tokens[i], tokens[j]
        return None

    def line_features(self, line):
        words = line.split()
        tokens = [self.g.normalize_word(w) for w in words]
        syllables = [self.syllables(t) if t else 0 for t in tokens]
        end = self.g.line_end_word(line)
        return {"words": len(words), "end_syllables": self.syllables(end) if end else 0,
                "big_words": sum(1 for s in syllables if s >= 3),
                "hard_words": [t for t, s in zip(tokens, syllables) if s >= 3 and t not in self.common],
                "internal_rhyme": self.internal_rhyme(tokens)}

    def allowed_end_syllables(self, case):
        listed = case.get("prompt_end_word_list") or []
        return 2 if any(self.syllables(w) >= 2 for w in listed) else 1


def complexity_reason_for_level(level, case, line, sounds, features=None):
    """filter_teacher.complexity_reason with the level passed explicitly (it reads it from the prompt)."""
    if level is None:
        return None
    f = features if features is not None else sounds.line_features(line)
    low, high = LEVEL_WORDS[level]
    if not low <= f["words"] <= high:
        return level.lower() + "_word_count"
    if level == "Simple":
        if f["hard_words"]:
            return "simple_hard_word"
        if f["end_syllables"] > sounds.allowed_end_syllables(case):
            return "simple_end_syllables"
    elif level == "Complex":
        if not (f["end_syllables"] >= 2 or f["internal_rhyme"] or f["big_words"] >= 2):
            return "complex_plain"
    return None


_SOUNDS = None


def sounds():
    global _SOUNDS
    if _SOUNDS is None:
        _SOUNDS = Sounds(g, g.load_dictionary(DICT_PATH), FREQ_PATH)
    return _SOUNDS


def grade_shown_lines(lines, level, allowed_words):
    """Apply the original level rules directly to the lines Android already accepted."""
    snd = sounds()
    case = {"prompt_end_word_list": allowed_words or []}
    results = []
    for line in lines:
        features = snd.line_features(line)
        reason = complexity_reason_for_level(level, case, line, snd, features)
        results.append({"line": line, **features, "reason": reason, "pass_level": reason is None})
    return results
