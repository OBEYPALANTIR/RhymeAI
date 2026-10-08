"""Shared level-aware end-word fixture: shared/fixtures/complexity-end-words-v1.json.

For each (anchor, rhymeType, complexity) the Android builder
`RhymeConstraint.candidateEndWords(anchor, type, complexity = level)` and
the eval's `scoring.candidate_end_words(anchor, type, complexity=level)` must
return `expected` word for word. Expected values come from this module; regenerate
them when the list rule changes:

    cd finetune && python3 -m eval.complexity_end_words_fixture

Anchors are PERFECT-type only: the eval's Near/Slant pools are a different,
older rule than the apps' and never matched them, so their lists are not pinned here.
The Android test (`ComplexityEndWordListTest`) and `test_complexity_end_words.py`
both read the file.
"""

from __future__ import annotations

import json
import os
import sys

FINETUNE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if FINETUNE not in sys.path:
    sys.path.insert(0, FINETUNE)

from eval import scoring  # noqa: E402

FIXTURE_PATH = os.path.join(scoring.REPO_ROOT, "shared", "fixtures", "complexity-end-words-v1.json")
LIMIT = 12
COMPLEXITIES = ("SIMPLE", "MODERATE", "COMPLEX")
# anchor -> why it is here
ANCHORS = {
    "home": "mixed syllables; Simple and Complex both have full lists",
    "night": "mostly one-syllable rhymes; Complex has to reach past the frequency cut",
    "road": "the eval's own fixture anchor",
    "alone": "mixed, with two-syllable rhymes near the top of the frequency order",
    "glow": "open vowel with many short rhymes",
    "time": "mixed",
    "world": "five one-syllable rhymes: the Simple list falls back to the remaining words",
    "love": "four one-syllable rhymes: the Simple list falls back to the remaining words",
    "river": "every rhyme has two or more syllables: all three lists are identical",
    "arrival": "fewer than twelve rhymes and no one-syllable rhyme at all",
    "surrender": "every rhyme has two or more syllables",
}

DESCRIPTION = (
    "Shared level-aware end-word fixture. For each case, Android "
    "RhymeConstraint.candidateEndWords(anchor, rhymeType, complexity = complexity) and "
    "finetune/eval/scoring.py candidate_end_words(anchor, rhymeType, complexity=complexity) "
    "must return `expected` word for word (limit 12, bundled dictionary and frequency list). "
    "MODERATE is the frequency order; COMPLEX puts words of two or more syllables first "
    "(stable); SIMPLE keeps one-syllable words only unless fewer than six exist, when the "
    "remaining words follow in their original order. Expected values were produced by "
    "finetune/eval/complexity_end_words_fixture.py; regenerate them there if the rule changes. "
    "iOS asserts the same rule on its own dictionary in RhymeConstraintTests.swift."
)


def build_cases():
    cases = []
    for anchor, note in ANCHORS.items():
        for complexity in COMPLEXITIES:
            cases.append({
                "anchor": anchor,
                "rhymeType": "PERFECT",
                "complexity": complexity,
                "note": note,
                "expected": scoring.candidate_end_words(anchor, "PERFECT", limit=LIMIT, complexity=complexity),
            })
    return cases


def build_fixture():
    return {"description": DESCRIPTION, "limit": LIMIT, "cases": build_cases()}


def main():
    fixture = build_fixture()
    with open(FIXTURE_PATH, "w", encoding="utf-8") as handle:
        json.dump(fixture, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print("wrote %s (%d cases)" % (FIXTURE_PATH, len(fixture["cases"])))


if __name__ == "__main__":
    main()
