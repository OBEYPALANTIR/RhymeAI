"""Deterministic-seedable random sampler for synthetic training cases.

Produces case dicts compatible with the eval case schema (finetune/eval/cases.py),
so they can be fed straight through eval.run_eval.prepare_case / score_case.
All prompt construction and phonetics come from the eval package — nothing is
duplicated here.

Task balance (expected, via weighted draw):
  ~50% suggestions, ~20% rewrite_passage, ~20% rewrite_word, ~10% synonyms.

sample_case(rng) returns a case dict, or None when the draw can't produce a
valid case (e.g. the rhyme constraint has no candidate end-words) — callers
should redraw with a different seed.
"""

from __future__ import annotations

import os
import random
import re
import sys

_FINETUNE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _FINETUNE_DIR not in sys.path:
    sys.path.insert(0, _FINETUNE_DIR)

from eval import prompts, scoring  # noqa: E402
from data import seed_songs  # noqa: E402

# ---------------------------------------------------------------------------
# Weights
# ---------------------------------------------------------------------------

TASK_WEIGHTS = [
    ("suggestions", 50),
    ("rewrite_passage", 20),
    ("rewrite_word", 20),
    ("synonyms", 10),
]
RHYME_TYPE_WEIGHTS = [("PERFECT", 60), ("NEAR", 25), ("SLANT", 15)]
COMPLEXITIES = ["SIMPLE", "MODERATE", "COMPLEX"]
ACTIONS = ["REPHRASE", "HARDER_RHYME", "PUNCH_UP"]
RHYME_SCHEMES = ["AABB", "ABAB", "ABCB", "AAAA"]
SYNONYM_LIMITS = [8, 8, 8, 8, 6, 10]

CONSTRAINED_SUGGESTION_P = 0.75   # else "start a new rhyme sound"
WHOLE_SONG_CONTEXT_P = 0.2
EMPTY_THEME_P = 0.1
SWAP_THEME_P = 0.15
REJECTED_WORDS_P = 0.4            # rewrite_word retry flavor
NO_LINE_CONTEXT_P = 0.1           # synonyms without a surrounding line

_HEADER_RE = re.compile(r"^\s*\[.+]\s*$")


def _weighted(rng: random.Random, pairs):
    total = sum(w for _, w in pairs)
    roll = rng.random() * total
    acc = 0.0
    for value, weight in pairs:
        acc += weight
        if roll < acc:
            return value
    return pairs[-1][0]


def _is_header(line: str) -> bool:
    trimmed = line.strip()
    if _HEADER_RE.match(line):
        return True
    return bool(trimmed and prompts._BARE_HEADER.fullmatch(trimmed))


def _lyric_line_indices(lines):
    return [
        i for i, line in enumerate(lines)
        if line.strip() and not _is_header(line)
    ]


def _section_fields(lyrics: str, line_index: int):
    """(section tuple-or-None, current_section name, SectionRef-or-None) for a
    line index — matching how eval cases encode sections."""
    refs = prompts.parse_section_map(lyrics)
    ref = prompts.section_at(refs, line_index)
    if ref.type == "UNKNOWN":
        return None, "UNKNOWN", None
    return (ref.type, ref.ordinal), ref.type, ref


def _pick_theme(rng: random.Random, song) -> str:
    if rng.random() < EMPTY_THEME_P:
        return ""
    if rng.random() < SWAP_THEME_P:
        return rng.choice(seed_songs.THEMES)
    return song["theme"]


# ---------------------------------------------------------------------------
# Per-task samplers
# ---------------------------------------------------------------------------

def _sample_suggestions(rng: random.Random, song):
    lines = song["lyrics"].split("\n")
    idxs = _lyric_line_indices(lines)
    if len(idxs) < 3:
        return None
    # Truncation point: keep at least 2 lyric lines of context before it.
    i = rng.choice(idxs[2:])
    truncated = "\n".join(lines[: i + 1])

    section, current_section, section_ref = _section_fields(truncated, i)
    rhyme_type = _weighted(rng, RHYME_TYPE_WEIGHTS)

    constrained = rng.random() < CONSTRAINED_SUGGESTION_P
    target_rhyme_line = None
    if constrained:
        target_rhyme_line = lines[i]
        # Mirror prepare_case exactly: skip when no constraint can be built.
        chorus_ends = prompts.first_chorus_end_words(truncated)
        constraint = prompts.suggestion_rhyme_constraint(
            target_rhyme_line, rhyme_type,
            section_ref=section_ref, chorus_end_words=chorus_ends,
        )
        if constraint is None:
            return None

    scheme = rng.choice(RHYME_SCHEMES)
    letter = rng.choice(sorted(set(scheme)))
    return {
        "task": "suggestions",
        "song_id": song["id"],
        "theme": _pick_theme(rng, song),
        "lyrics": truncated,
        "target_rhyme_line": target_rhyme_line,
        "rhyme_type": rhyme_type,
        "rhyme_scheme": scheme,
        "current_letter": letter,
        "section": section,
        "current_section": current_section,
        "complexity": rng.choice(COMPLEXITIES),
        "use_whole_song_context": rng.random() < WHOLE_SONG_CONTEXT_P,
    }


def _sample_rewrite_passage(rng: random.Random, song):
    lyrics = song["lyrics"]
    lines = lyrics.split("\n")
    idxs = _lyric_line_indices(lines)
    if not idxs:
        return None
    j = rng.choice(idxs)
    span = 2 if (rng.random() < 0.5 and (j + 1) in idxs) else 1
    selection = "\n".join(lines[j: j + span])

    _, current_section, _ = _section_fields(lyrics, j)
    return {
        "task": "rewrite_passage",
        "song_id": song["id"],
        "action": rng.choice(ACTIONS),
        "lyrics": lyrics,
        "selection": selection,
        "current_section": current_section,
    }


def _last_whole_word_offset(lyrics: str, word: str):
    """Offset of the LAST raw occurrence of `word` — but only if that
    occurrence is a whole word, because eval's selection_start_for uses
    lyrics.rindex(word) and we must agree with it."""
    pos = lyrics.rfind(word)
    if pos < 0:
        return None
    before = lyrics[pos - 1] if pos > 0 else " "
    after_idx = pos + len(word)
    after = lyrics[after_idx] if after_idx < len(lyrics) else " "
    word_ch = re.compile(r"[\w']")
    if word_ch.match(before) or word_ch.match(after):
        return None
    return pos


def _bank_words_in_song(lyrics: str):
    found = []
    for word in sorted(seed_songs.WORD_BANK):
        if _last_whole_word_offset(lyrics, word) is not None:
            found.append(word)
    return found


def _sample_rewrite_word(rng: random.Random, song):
    lyrics = song["lyrics"]
    candidates = _bank_words_in_song(lyrics)
    if not candidates:
        return None
    word = rng.choice(candidates)
    offset = _last_whole_word_offset(lyrics, word)
    line_index = lyrics[:offset].count("\n")
    _, current_section, _ = _section_fields(lyrics, line_index)

    rejected = []
    if rng.random() < REJECTED_WORDS_P:
        synonyms = seed_songs.WORD_BANK[word]
        rejected = rng.sample(synonyms, rng.choice([1, 2]))

    return {
        "task": "rewrite_word",
        "song_id": song["id"],
        "action": rng.choice(ACTIONS),
        "lyrics": lyrics,
        "selection": word,
        "selection_word": word,
        "current_section": current_section,
        "rejected": rejected,
    }


def _sample_synonyms(rng: random.Random, song):
    lyrics = song["lyrics"]
    pattern_cache = {}
    options = []
    for word in sorted(seed_songs.WORD_BANK):
        pattern = pattern_cache.setdefault(
            word, re.compile(r"(?<![\w'])%s(?![\w'])" % re.escape(word))
        )
        for line in lyrics.split("\n"):
            if not line.strip() or _is_header(line):
                continue
            if pattern.search(line):
                options.append((word, line.strip()))
    if not options:
        return None
    word, line = rng.choice(options)
    line_context = "" if rng.random() < NO_LINE_CONTEXT_P else line
    return {
        "task": "synonyms",
        "song_id": song["id"],
        "word": word,
        "line_context": line_context,
        "limit": rng.choice(SYNONYM_LIMITS),
    }


_SAMPLERS = {
    "suggestions": _sample_suggestions,
    "rewrite_passage": _sample_rewrite_passage,
    "rewrite_word": _sample_rewrite_word,
    "synonyms": _sample_synonyms,
}


def sample_case(rng: random.Random):
    """One random case dict (eval-compatible), or None if this draw is
    unbuildable (caller redraws with a fresh seed)."""
    task = _weighted(rng, TASK_WEIGHTS)
    song = rng.choice(seed_songs.SONGS)
    case = _SAMPLERS[task](rng, song)
    if case is not None:
        case.setdefault("id", "sampled")
    return case


# ---------------------------------------------------------------------------
# Self-test: python3 finetune/data/sample_cases.py
# ---------------------------------------------------------------------------

def _self_test():
    from collections import Counter
    from eval.prompts import TURN_MARKERS
    from eval.run_eval import prepare_case

    counts = Counter()
    skipped = 0
    for i in range(400):
        rng = random.Random("selftest-%d" % i)
        case = sample_case(rng)
        if case is None:
            skipped += 1
            continue
        prepared = prepare_case(case)  # must not raise
        assert not any(marker in prepared["user_prompt"] for marker in TURN_MARKERS)
        counts[case["task"]] += 1

    # Determinism check.
    a = sample_case(random.Random("selftest-7"))
    b = sample_case(random.Random("selftest-7"))
    assert a == b, "sampler is not deterministic for a fixed seed"

    total = sum(counts.values())
    print("sampled %d cases (%d skipped draws)" % (total, skipped))
    for task, n in sorted(counts.items()):
        print("  %-16s %4d  (%.0f%%)" % (task, n, 100.0 * n / total))


if __name__ == "__main__":
    _self_test()
