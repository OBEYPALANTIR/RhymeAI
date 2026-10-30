"""Scoring / phonetics for the RhymeAI local-model eval harness.

# PARITY
Ports of the Android sources (do not let these drift):
  - android/.../util/ProsodyAnalyzer.kt   (normalizeWord, rhymeKeys, findRhymes,
                                            rhymeRelation / tailRelation, syllable
                                            counting, PronunciationDictionary)
  - android/.../util/RhymeConstraint.kt   (lineEndWord, candidateEndWords, levelEndWords, rhymeTier)
  - android/.../util/WordFrequency.kt     (frequency-rank re-sort of rhyme pools)
  - android/.../util/SyllableCounter.kt   (dictionary-first with heuristic fallback)
  - android/.../service/AIService.kt      (output-cleaning regexes used as validators)

Only what scoring needs is ported. Stdlib only.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DICT_PATH = REPO_ROOT / "shared" / "pronunciation" / "cmudict-rhymeai.tsv"
FREQ_PATH = REPO_ROOT / "shared" / "pronunciation" / "word-frequency.txt"

# ---------------------------------------------------------------------------
# ProsodyAnalyzer constants (ported verbatim)
# ---------------------------------------------------------------------------

VOWELS = {
    "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY",
    "OW", "OY", "UH", "UW",
}

STOPWORDS = {
    "the", "a", "an", "and", "or", "but", "is", "are", "was", "were",
    "be", "to", "of", "in", "on", "at", "by", "for", "with", "as",
    "it", "its", "this", "that", "these", "those", "i", "you", "he",
    "she", "we", "they", "them", "his", "her", "our", "their", "my",
    "do", "does", "did", "have", "has", "had", "not", "if", "so", "no",
}

# Ordered; each pair is applied with replace-all, in sequence.
SUBSTITUTIONS = [
    ("tion", "shn"),
    ("sion", "shn"),
    ("cion", "shn"),
    ("cian", "shn"),
    ("tial", "shl"),
    ("cial", "shl"),
    ("ough", "of"),
    ("augh", "af"),
    ("eigh", "ay"),
    ("ight", "ite"),
    ("ph", "f"),
    ("ck", "k"),
    ("qu", "kw"),
    ("wh", "w"),
    ("x", "ks"),
]

# LyricTokenizer.wordPattern: straight, U+2019 and U+02BC apostrophes keep a contraction whole.
APOSTROPHES = "'\u2019\u02BC"
WORD_PATTERN = re.compile(r"[a-zA-Z'\u2019\u02BC]+")

_STRESS_SUFFIX = re.compile(r"[0-2]$")


def normalize_word(word: str) -> str:
    """ProsodyAnalyzer.normalizeWord: lowercase, keep [a-z'] (curly apostrophes read as '), trim apostrophes."""
    kept = "".join(
        "'" if ch in APOSTROPHES else ch for ch in word.lower() if ("a" <= ch <= "z") or ch in APOSTROPHES
    )
    return kept.strip("'")


def base_phone(phone: str) -> str:
    return _STRESS_SUFFIX.sub("", phone)


def stress_for_phone(phone: str):
    if not phone:
        return None
    last = phone[-1]
    if last.isdigit():
        digit = int(last)
        if 0 <= digit <= 2:
            return digit
    return None


# ---------------------------------------------------------------------------
# Pronunciation dictionary + word frequency
# ---------------------------------------------------------------------------

class PronunciationDictionary:
    """word -> list of pronunciation variants (each a list of ARPABET phones)."""

    def __init__(self, entries):
        self.entries = entries

    def pronunciations(self, normalized_word):
        return self.entries.get(normalized_word, [])

    @property
    def word_count(self):
        return len(self.entries)

    @classmethod
    def from_file(cls, path=DICT_PATH):
        entries = {}
        with open(path, "r", encoding="utf-8") as handle:
            for row in handle:
                row = row.rstrip("\n")
                if not row.strip() or row.startswith("#"):
                    continue
                tab_index = row.find("\t")
                if tab_index <= 0:
                    continue
                word = row[:tab_index]
                variants = []
                for variant in row[tab_index + 1:].split("|"):
                    phones = [p for p in variant.strip().split() if p]
                    if phones:
                        variants.append(phones)
                if variants:
                    entries[word] = variants
        if not entries:
            raise ValueError("Pronunciation dictionary is empty")
        return cls(entries)


class WordFrequency:
    """word -> 1-based frequency rank; unknown words sort last."""

    UNKNOWN_RANK = 2 ** 31 - 1

    def __init__(self, rank_map=None):
        self.rank_map = rank_map or {}

    def rank_of(self, word):
        return self.rank_map.get(word.lower(), self.UNKNOWN_RANK)

    def sort_by_frequency(self, words):
        if not self.rank_map:
            return list(words)
        return sorted(words, key=self.rank_of)  # stable, like Kotlin sortedBy

    @classmethod
    def from_file(cls, path=FREQ_PATH):
        rank_map = {}
        rank = 1
        try:
            with open(path, "r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    word = line.lower()
                    if word and word not in rank_map:
                        rank_map[word] = rank
                        rank += 1
        except OSError:
            pass  # degrade gracefully, exactly like the app
        return cls(rank_map)


_shared_dictionary = None
_shared_frequency = None


def shared_dictionary() -> PronunciationDictionary:
    global _shared_dictionary
    if _shared_dictionary is None:
        _shared_dictionary = PronunciationDictionary.from_file()
    return _shared_dictionary


def shared_frequency() -> WordFrequency:
    global _shared_frequency
    if _shared_frequency is None:
        _shared_frequency = WordFrequency.from_file()
    return _shared_frequency


# ---------------------------------------------------------------------------
# Rhyme keys (ProsodyAnalyzer.rhymeKeys / rhymeKeysForPhones / fallbackRhymeKeys)
# ---------------------------------------------------------------------------

def rhyme_keys_for_phones(phones, max_depth):
    vowel_indexes = [i for i, p in enumerate(phones) if base_phone(p) in VOWELS]
    if not vowel_indexes:
        return []
    stressed = [i for i in vowel_indexes if (stress_for_phone(phones[i]) or 0) > 0]
    anchors = stressed if stressed else vowel_indexes
    tail = anchors[-max_depth:] if max_depth > 0 else []
    return [
        " ".join(base_phone(p) for p in phones[index:])
        for index in reversed(tail)
    ]


def _fallback_rhyme_keys(word, max_depth):
    phonetic = normalize_word(word)
    if len(phonetic) < 2 or phonetic in STOPWORDS:
        return []
    for src, dst in SUBSTITUTIONS:
        phonetic = phonetic.replace(src, dst)
    if len(phonetic) > 2 and phonetic.endswith("e") and not phonetic.endswith("le"):
        phonetic = phonetic[:-1]

    starts = []
    in_group = False
    for index, ch in enumerate(phonetic):
        is_vowel = ch in "aeiou" or (ch == "y" and index > 0)
        if is_vowel and not in_group:
            starts.append(index)
        in_group = is_vowel

    tail = starts[-max_depth:] if max_depth > 0 else []
    return [phonetic[start:] for start in reversed(tail)]


def rhyme_keys(word, max_depth=2, dictionary=None):
    dictionary = dictionary or shared_dictionary()
    normalized = normalize_word(word)
    if len(normalized) < 2 or normalized in STOPWORDS:
        return []
    variants = dictionary.pronunciations(normalized)
    if not variants:
        return _fallback_rhyme_keys(normalized, max_depth)
    seen = set()
    keys = []
    for phones in variants:
        for key in rhyme_keys_for_phones(phones, max_depth):
            if key not in seen:
                seen.add(key)
                keys.append(key)
    return keys


# ---------------------------------------------------------------------------
# findRhymes + candidateEndWords (ProsodyAnalyzer / RhymeConstraint)
# ---------------------------------------------------------------------------

class RhymeMatches:
    """Exclusive pools: a word that is perfect under any pronunciation pair is
    in neither near nor slant; near and slant never overlap."""

    def __init__(self, perfect, near, multi, slant=()):
        self.perfect = perfect
        self.near = near
        self.multi = multi
        self.slant = list(slant)

    @property
    def is_empty(self):
        return not (self.perfect or self.near or self.multi or self.slant)


EMPTY_MATCHES = RhymeMatches([], [], [])

# ProsodyAnalyzer.functionWords: stopwords plus grammatical words, ranked after
# content words in near and slant lists.
FUNCTION_WORDS = STOPWORDS | set("""
me mine myself your yours yourself yourselves him himself hers herself itself us ours ourselves theirs themselves
who whom whose which what whatever whoever whichever when whenever where wherever why how however whether
while whereas though although because unless then than yet nor there here some any each every either neither
both all such more most much many few less least into onto from upon unto via per among amongst toward
towards during until till since despite except against between through within without across am been being
having will would shall should can could may might must ought just very too also really quite rather else
i'm you're he's she's it's we're they're i've you've we've they've i'd you'd he'd she'd we'd they'd i'll
you'll he'll she'll we'll they'll isn't aren't wasn't weren't don't doesn't didn't won't wouldn't can't couldn't
shouldn't that's there's what's who's let's ain't""".split())

_INFLECTION_SUFFIXES = {"s", "es", "'s", "ed", "ing"}

# Same family: plosives, fricatives (with affricates), nasals.
_CONSONANT_FAMILIES = [
    {"P", "B", "T", "D", "K", "G"},
    {"F", "V", "TH", "DH", "S", "Z", "SH", "ZH", "CH", "JH"},
    {"M", "N", "NG"},
]

# TailRelation.rank: lower is better.
_RELATION_RANK = {"PERFECT": 0, "NEAR": 10, "SLANT": 20}


def is_vowel_phone(phone):
    return phone in VOWELS


def is_function_word(word):
    return word in FUNCTION_WORDS


def is_inflection(word, base):
    """ProsodyAnalyzer.isInflection: `word` is `base` plus an inflection."""
    if not base or len(word) <= len(base):
        return False
    stems = [base, base[:-1]] if base.endswith("e") else [base]
    return any(word.startswith(s) and word[len(s):] in _INFLECTION_SUFFIXES for s in stems)


def is_spelled_as_word(word):
    """Rejects abbreviations spelled without a vowel letter ("mr", "st")."""
    return any(ch in "aeiouy" for ch in word)


def rhyme_tail_for_phones(phones):
    """ProsodyAnalyzer.rhymeTailForPhones: (vowel, coda) from the last stressed
    vowel (or the last vowel when none is stressed); stress digits removed."""
    vowel_indexes = [i for i, p in enumerate(phones) if base_phone(p) in VOWELS]
    if not vowel_indexes:
        return None
    stressed = [i for i in vowel_indexes if (stress_for_phone(phones[i]) or 0) > 0]
    index = (stressed or vowel_indexes)[-1]
    return (base_phone(phones[index]), tuple(base_phone(p) for p in phones[index + 1:]))


def _close_consonant(a, b):
    return any(a in family and b in family for family in _CONSONANT_FAMILIES)


def _close_coda_edit(lhs, rhs):
    """One same-family consonant substitution, or one consonant added or dropped."""
    if len(lhs) == len(rhs):
        differences = [(a, b) for a, b in zip(lhs, rhs) if a != b]
        if len(differences) != 1:
            return False
        a, b = differences[0]
        return not is_vowel_phone(a) and not is_vowel_phone(b) and _close_consonant(a, b)
    if abs(len(lhs) - len(rhs)) != 1:
        return False
    shorter, longer = (lhs, rhs) if len(lhs) < len(rhs) else (rhs, lhs)
    return any(
        not is_vowel_phone(longer[i]) and longer[:i] + longer[i + 1:] == shorter
        for i in range(len(longer))
    )


def _adds_unstressed_syllable(lhs, rhs):
    """The longer coda is the shorter plus exactly one more (unstressed) syllable."""
    if len(lhs) == len(rhs):
        return False
    shorter, longer = (lhs, rhs) if len(lhs) < len(rhs) else (rhs, lhs)
    if longer[:len(shorter)] != shorter:
        return False
    return sum(1 for p in longer[len(shorter):] if is_vowel_phone(p)) == 1


def _is_stress_shift(lhs, rhs):
    """One word's stressed tail is the other's unstressed ending ("free"/"happy")."""
    lhs_full = (lhs[0],) + lhs[1]
    rhs_full = (rhs[0],) + rhs[1]
    return ((len(rhs[1]) >= len(lhs_full) and rhs[1][-len(lhs_full):] == lhs_full)
            or (len(lhs[1]) >= len(rhs_full) and lhs[1][-len(rhs_full):] == rhs_full))


def tail_relation(target, candidate):
    """ProsodyAnalyzer.tailRelation on (vowel, coda) tails: ("NEAR", 1|2),
    ("SLANT", 1) or None. Near: same stressed vowel and a close coda edit, an
    extra unstressed syllable, or shifted stress. Slant: consonance (same coda,
    different vowel) or assonance (same vowel and syllable shape). A vowel
    before R is its own vowel."""
    if target == candidate:
        return None
    if target[0] == candidate[0]:
        target_r = bool(target[1]) and target[1][0] == "R"
        candidate_r = bool(candidate[1]) and candidate[1][0] == "R"
        if target_r == candidate_r:
            target_rest = target[1][1:] if target_r else target[1]
            candidate_rest = candidate[1][1:] if candidate_r else candidate[1]
            if _close_coda_edit(target_rest, candidate_rest):
                return ("NEAR", 1)
            if _adds_unstressed_syllable(target_rest, candidate_rest):
                return ("NEAR", 2)
            if _is_stress_shift(target, candidate):
                return ("NEAR", 2)
            if ([p for p in target_rest if is_vowel_phone(p)]
                    == [p for p in candidate_rest if is_vowel_phone(p)]):
                return ("SLANT", 1)
        return ("NEAR", 2) if _is_stress_shift(target, candidate) else None
    if _is_stress_shift(target, candidate):
        return ("NEAR", 2)
    if target[1] and target[1] == candidate[1]:
        return ("SLANT", 1)
    return None


def _rhyme_profile(phones):
    """ProsodyAnalyzer.RhymeProfile for one pronunciation: (key, multi_key, tail)."""
    keys = rhyme_keys_for_phones(phones, 2)
    tail = rhyme_tail_for_phones(phones)
    if not keys or tail is None:
        return None
    return (keys[0], keys[1] if len(keys) > 1 else None, tail)


def _profiles(variants):
    return [p for p in (_rhyme_profile(phones) for phones in variants) if p is not None]


def best_relation(target_profiles, candidate_profiles):
    """ProsodyAnalyzer.bestRelation: the closest relation over every target x
    candidate pronunciation, Perfect > Near > Slant, as (type, tier) or None."""
    best = None
    for t_key, t_multi, t_tail in target_profiles:
        for c_key, c_multi, c_tail in candidate_profiles:
            if c_key == t_key or (t_multi is not None and c_multi == t_multi):
                return ("PERFECT", 0)
            relation = tail_relation(t_tail, c_tail)
            if relation is None:
                continue
            if best is None or _RELATION_RANK[relation[0]] + relation[1] < _RELATION_RANK[best[0]] + best[1]:
                best = relation
    return best


def rhyme_relation(candidate_word, target_word, dictionary=None):
    """ProsodyAnalyzer.rhymeRelation: 'PERFECT' | 'NEAR' | 'SLANT' | None over
    every pronunciation of both words; the same word is None."""
    dictionary = dictionary or shared_dictionary()
    candidate = normalize_word(candidate_word)
    target = normalize_word(target_word)
    if candidate == target:
        return None
    relation = best_relation(
        _profiles(dictionary.pronunciations(target)),
        _profiles(dictionary.pronunciations(candidate)),
    )
    return relation[0] if relation else None


_index_built_for = None
_perfect_by_key = {}
_multi_by_key = {}
_profiles_by_word = {}
_words_by_vowel = {}
_words_by_coda = {}
_words_by_weak_tail = {}


def _ensure_index(dictionary):
    """ProsodyAnalyzer.ensureIndex. Stopwords are left out of the perfect and
    multi pools but keep their tails, as on Android."""
    global _index_built_for, _perfect_by_key, _multi_by_key, _profiles_by_word
    global _words_by_vowel, _words_by_coda, _words_by_weak_tail
    if _index_built_for is dictionary:
        return
    perfect_build = {}
    multi_build = {}
    profiles_build = {}
    vowel_build = {}
    coda_build = {}
    weak_build = {}
    for word, variants in dictionary.entries.items():
        if len(word) < 2:
            continue
        is_stopword = word in STOPWORDS
        seen_k0 = set()
        seen_k1 = set()
        profiles = []
        for phones in variants:
            ks = rhyme_keys_for_phones(phones, 2)
            if not ks:
                continue
            k0 = ks[0]
            tail = rhyme_tail_for_phones(phones)
            if tail is not None:
                profiles.append((k0, ks[1] if len(ks) > 1 else None, tail))
            if is_stopword:
                continue
            if k0 not in seen_k0:
                seen_k0.add(k0)
                perfect_build.setdefault(k0, []).append(word)
            if len(ks) < 2:
                continue
            k1 = ks[1]
            if k1 not in seen_k1:
                seen_k1.add(k1)
                multi_build.setdefault(k1, []).append(word)
        profiles_build[word] = profiles
        seen_tails = set()
        for _, _, tail in profiles:
            if tail in seen_tails:
                continue
            seen_tails.add(tail)
            vowel, coda = tail
            vowel_build.setdefault(vowel, []).append(word)
            if coda:
                coda_build.setdefault(coda, []).append(word)
            # Unstressed syllables after the stress ("happy" ends in an
            # unstressed IY), for stress-shifted near rhymes.
            for i, phone in enumerate(coda):
                if is_vowel_phone(phone):
                    weak_build.setdefault(coda[i:], []).append(word)
    _perfect_by_key = perfect_build
    _multi_by_key = multi_build
    _profiles_by_word = profiles_build
    _words_by_vowel = vowel_build
    _words_by_coda = coda_build
    _words_by_weak_tail = weak_build
    _index_built_for = dictionary


def _songwriter_order(relations, word_frequency):
    """Content words before function words, closer relations first, then
    common before rare, then spelling so ties are identical on every platform."""
    return sorted(
        relations,
        key=lambda w: (1 if is_function_word(w) else 0, relations[w][1], word_frequency.rank_of(w), w),
    )


def find_rhymes(word, perfect_limit=60, near_limit=30, multi_limit=30,
                dictionary=None, word_frequency=None):
    """ProsodyAnalyzer.findRhymes: exclusive perfect / multi / near / slant pools."""
    dictionary = dictionary or shared_dictionary()
    word_frequency = word_frequency or shared_frequency()
    normalized = normalize_word(word)
    if len(normalized) < 2 or normalized in STOPWORDS:
        return EMPTY_MATCHES
    if dictionary.word_count == 0:
        return EMPTY_MATCHES

    keys = rhyme_keys(word, max_depth=2, dictionary=dictionary)
    if not keys:
        return EMPTY_MATCHES
    k0 = keys[0]
    k1 = keys[1] if len(keys) > 1 else None

    _ensure_index(dictionary)
    perfect_all = [w for w in _perfect_by_key.get(k0, []) if w != normalized]
    perfect_set = set(perfect_all)
    if k1 is not None:
        multi_all = [
            w for w in _multi_by_key.get(k1, [])
            if w != normalized and w not in perfect_set
        ]
    else:
        multi_all = []
    exclude = perfect_set | set(multi_all)

    # Every pronunciation of the target, so "abuse" (/s/ and /z/) is
    # classified the same way rhyme_relation verifies a returned line.
    variants = dictionary.pronunciations(normalized)
    target_profiles = _profiles(variants)
    near = []
    slant = []
    if target_profiles and rhyme_tail_for_phones(variants[0]) is not None:
        # Every word that can stand in a near or slant relation to any target
        # pronunciation: the same stressed vowel, the same coda, or a
        # stress-shifted tail.
        pool = set()
        for vowel, coda in {p[2] for p in target_profiles}:
            pool.update(_words_by_vowel.get(vowel, ()))
            if coda:
                pool.update(_words_by_coda.get(coda, ()))
            pool.update(_words_by_weak_tail.get((vowel,) + coda, ()))
            for other in {p for p in coda if is_vowel_phone(p)}:
                if other != vowel:
                    pool.update(_words_by_vowel.get(other, ()))
        # Each word takes its closest relation over every pronunciation pair;
        # a word that is perfect under any pairing is in neither list.
        best = {}
        for candidate in pool:
            if (candidate == normalized or candidate in exclude
                    or is_inflection(candidate, normalized) or not is_spelled_as_word(candidate)):
                continue
            relation = best_relation(target_profiles, _profiles_by_word.get(candidate, []))
            if relation is not None and relation[0] != "PERFECT":
                best[candidate] = relation
        near = _songwriter_order({w: r for w, r in best.items() if r[0] == "NEAR"}, word_frequency)
        slant = _songwriter_order({w: r for w, r in best.items() if r[0] == "SLANT"}, word_frequency)

    return RhymeMatches(
        perfect=word_frequency.sort_by_frequency(perfect_all)[:perfect_limit],
        near=near[:near_limit],
        multi=word_frequency.sort_by_frequency(multi_all)[:multi_limit],
        slant=slant[:near_limit],
    )


def line_end_word(line):
    """RhymeConstraint.lineEndWord."""
    matches = WORD_PATTERN.findall(line)
    if not matches:
        return ""
    return normalize_word(matches[-1])


# RhymeConstraint.CANDIDATE_LIMIT: words the prompt lists as allowed endings.
CANDIDATE_LIMIT = 12

# RhymeConstraint.SIMPLE_MIN_MONOSYLLABLES: a Simple list keeps only
# one-syllable words unless fewer than this many exist, in which case the
# remaining words follow in their original order (some anchors, "arrival"
# for one, have no one-syllable rhyme at all).
SIMPLE_MIN_MONOSYLLABLES = 6


def candidate_end_words(target_word, rhyme_type, limit=CANDIDATE_LIMIT, dictionary=None,
                        complexity="MODERATE"):
    """RhymeConstraint.candidateEndWords. rhyme_type: 'PERFECT'|'NEAR'|'SLANT';
    complexity: 'SIMPLE'|'MODERATE'|'COMPLEX' (RhymeComplexity name)."""
    dictionary = dictionary or shared_dictionary()
    ordered = ordered_candidates(target_word, rhyme_type, dictionary=dictionary)
    return level_end_words(ordered, complexity, limit, dictionary=dictionary)


def ordered_candidates(target_word, rhyme_type, dictionary=None):
    """RhymeConstraint.orderedCandidates: every word in the requested relation to
    the target, ranked and deduplicated, before any level ordering or limit."""
    dictionary = dictionary or shared_dictionary()
    matches = find_rhymes(target_word, dictionary=dictionary)
    if matches.is_empty:
        return []
    # Each mode returns only its named phonetic relation, as in the apps. Perfect
    # keeps the exact and multisyllabic pools; Near and Slant are exclusive
    # and already ranked by find_rhymes.
    if rhyme_type == "PERFECT":
        pools = [matches.perfect, matches.multi]
    elif rhyme_type == "NEAR":
        pools = [matches.near]
    elif rhyme_type == "SLANT":
        pools = [matches.slant]
    else:
        raise ValueError("unknown rhyme type %r" % (rhyme_type,))
    normalized_target = normalize_word(target_word)
    ordered = []
    seen = set()
    for pool in pools:
        for word in pool:
            if word != normalized_target and word not in seen:
                seen.add(word)
                ordered.append(word)
    return ordered


def level_end_words(ordered, complexity, limit, dictionary=None):
    """RhymeConstraint.levelEndWords: the complexity level's view of a
    relation's ranked candidates, cut to `limit`.

    COMPLEX: words of two or more syllables first, then the rest; each group
    keeps its frequency order (a stable partition). SIMPLE: one-syllable words
    only, unless fewer than SIMPLE_MIN_MONOSYLLABLES exist, when the remaining
    words follow in their original order. MODERATE: unchanged.
    Syllables come from syllable_count_word, the same dictionary-first count
    the apps' ProsodyAnalyzer uses.
    """
    if complexity == "MODERATE":
        return list(ordered[:limit])
    syllables = {w: syllable_count_word(w, dictionary=dictionary) for w in ordered}
    if complexity == "COMPLEX":
        multi = [w for w in ordered if syllables[w] >= 2]
        rest = [w for w in ordered if syllables[w] < 2]
        return (multi + rest)[:limit]
    if complexity == "SIMPLE":
        mono = [w for w in ordered if syllables[w] == 1]
        if len(mono) >= SIMPLE_MIN_MONOSYLLABLES:
            return mono[:limit]
        rest = [w for w in ordered if syllables[w] != 1]
        return (mono + rest)[:limit]
    raise ValueError("unknown complexity %r" % (complexity,))


def rhyme_tier(line, target_word, dictionary=None):
    """RhymeConstraint.rhymeTier: 3 = slant, 2 = perfect/multi, 1 = near,
    0 = miss, classified by rhyme_relation over every pronunciation."""
    end_word = line_end_word(line)
    if not end_word:
        return 0
    return {"PERFECT": 2, "NEAR": 1, "SLANT": 3}.get(
        rhyme_relation(end_word, target_word, dictionary=dictionary), 0)


def is_perfect_rhyme(word_a, word_b, dictionary=None):
    """True when the words share a depth-1 rhyme key (last stressed vowel tail)
    and are not the same normalized word."""
    dictionary = dictionary or shared_dictionary()
    a = normalize_word(word_a)
    b = normalize_word(word_b)
    if not a or not b or a == b:
        return False
    keys_a = set(rhyme_keys(a, max_depth=1, dictionary=dictionary))
    keys_b = set(rhyme_keys(b, max_depth=1, dictionary=dictionary))
    return bool(keys_a & keys_b)


# ---------------------------------------------------------------------------
# Syllable counting (SyllableCounter / ProsodyAnalyzer.analyzeWord fallback)
# ---------------------------------------------------------------------------

def _fallback_syllable_count(word):
    w = normalize_word(word)
    if not w:
        return 0
    if len(w) <= 2:
        return 1

    count = 0
    prev_vowel = False
    vowel_letters = "aeiouy"
    for ch in w:
        is_vowel = ch in vowel_letters
        if is_vowel and not prev_vowel:
            count += 1
        prev_vowel = is_vowel

    if w.endswith("e") and not w.endswith("le") and count > 1:
        count -= 1
    ends_in_les = w.endswith("les")
    if ends_in_les and len(w) >= 4 and w[-4] in vowel_letters and count > 1:
        count -= 1
    if (not ends_in_les and w.endswith("es")
            and not w.endswith("ses") and not w.endswith("zes") and count > 1):
        count -= 1
    if w.endswith("ed") and not w.endswith("ted") and not w.endswith("ded") and count > 1:
        count -= 1

    return max(count, 1)


def syllable_count_word(word, dictionary=None):
    """Dictionary-first (first variant's stress-pattern length), heuristic fallback."""
    dictionary = dictionary or shared_dictionary()
    normalized = normalize_word(word)
    if not normalized:
        return 0
    variants = dictionary.pronunciations(normalized)
    if not variants:
        return len(_fallback_stress_pattern(normalized))
    phones = variants[0]
    return sum(1 for p in phones if stress_for_phone(p) is not None)


def _fallback_stress_pattern(word):
    count = _fallback_syllable_count(word)
    return [1 if i == 0 else 0 for i in range(count)]


def syllable_count(line, dictionary=None):
    """Syllables across all words in a line (ProsodyAnalyzer.countText)."""
    return sum(
        syllable_count_word(match, dictionary=dictionary)
        for match in WORD_PATTERN.findall(line)
    )


# ---------------------------------------------------------------------------
# Output format validators (mirroring AIService.kt cleaning regexes)
# ---------------------------------------------------------------------------

LIST_PREFIX_RE = re.compile(r"^\s*(?:[-*]\s+|\d+[.)\-:]\s*)")
PROMPT_ECHO_RE = re.compile(
    r"^(?:task:|theme:|rhyme scheme:|lyrics context:|rules:|return exactly|"
    r"return only|one suggestion|no numbering|do not|keep each|you are rhymeai|"
    r"sure[, ]|here are|i can(?:not|'t)|as an ai)",
    re.IGNORECASE,
)
# Gemma 4 control tokens are pipe-delimited (<|turn>, <turn|>, <|channel>,
# <channel|>, <|think|>, ...); the app rejects <|turn>/<turn|> the same way
# (AIService.swift containsLocalControlMarker).
GEMMA4_CONTROL_TOKEN = r"<\|[a-z_]+\|?>|<[a-z_]+\|>"
CONTROL_MARKER_RE = re.compile(
    GEMMA4_CONTROL_TOKEN + r"|"
    r"<?/?(?:start_of_turn|end_of_turn)>?\w*|_?response>|_?model_response>|"
    r"assistant_response>|model_response>",
    re.IGNORECASE,
)
SINGLE_WORD_RE = re.compile(r"(?:[^\W_]|['-])+$", re.UNICODE)
_NORMALIZE_KEY_RE = re.compile(r"[^a-z0-9]+")
_MARKDOWN_RE = re.compile(r"(```|\*\*|__|^#+\s)", re.MULTILINE)


def normalize_suggestion_key(text):
    """AIService.normalizeSuggestionKey."""
    return _NORMALIZE_KEY_RE.sub("", text.lower().strip())


def is_single_word(text):
    """AIService.isSingleWordSelection."""
    return bool(SINGLE_WORD_RE.fullmatch(text.strip()))


def word_count(line):
    return len([w for w in line.split() if w.strip()])


def strip_model_output(raw):
    """Light port of stripLocalModelArtifacts: cut control markers, fences."""
    text = raw.strip()
    # Drop anything up to and including a "model turn" marker the model echoed,
    # in either envelope (<start_of_turn>model or Gemma 4's <|turn>model). Any
    # other Gemma 4 control token stays, so CONTROL_MARKER_RE rejects it.
    payload = re.match(
        r".*(?:<start_of_turn>\s*model|start_of_turn>\s*model|<?\|turn>\s*model|"
        r"_?model_response>|assistant_response>|model_response>)\s*",
        text, re.IGNORECASE | re.DOTALL,
    )
    if payload:
        text = text[payload.end():]
    text = text.split("<end_of_turn>")[0].split("end_of_turn>")[0]
    lines = []
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped.lower() == "```json" or stripped == "```":
            continue
        lines.append(line)
    text = "\n".join(lines).strip()
    for prefix in ("```json", "```"):
        if text.startswith(prefix):
            text = text[len(prefix):]
    if text.endswith("```"):
        text = text[:-3]
    return text.strip()


def _line_violations(line, max_words=16):
    """Format violations for one candidate lyric line."""
    violations = []
    if LIST_PREFIX_RE.search(line):
        violations.append("numbering_or_bullet")
    stripped = line.strip()
    if len(stripped) >= 2 and stripped[0] in "\"'“”‘’" and stripped[-1] in "\"'“”‘’":
        violations.append("quoted")
    if _MARKDOWN_RE.search(line):
        violations.append("markdown")
    if PROMPT_ECHO_RE.search(stripped):
        violations.append("prompt_echo")
    if CONTROL_MARKER_RE.search(line):
        violations.append("control_marker")
    if word_count(stripped) >= max_words:
        violations.append("over_16_words")
    return violations


def validate_suggestions(raw_output, expected_count, lyrics):
    """Format validation for a suggestions response.

    Returns dict: lines, violations (list of (line_index, [violation,...])),
    passed (bool).
    """
    text = strip_model_output(raw_output)
    lines = [l for l in text.split("\n") if l.strip()]
    violations = []

    if len(lines) != expected_count:
        violations.append((-1, ["expected_%d_lines_got_%d" % (expected_count, len(lines))]))

    existing = {
        normalize_suggestion_key(l)
        for l in lyrics.split("\n")
        if normalize_suggestion_key(l)
    }
    seen = set()
    for index, line in enumerate(lines):
        line_violations = _line_violations(line)
        key = normalize_suggestion_key(line)
        if not key:
            line_violations.append("empty_after_normalize")
        else:
            if key in existing:
                line_violations.append("copies_existing_line")
            if key in seen:
                line_violations.append("duplicate_suggestion")
            seen.add(key)
        if line_violations:
            violations.append((index, line_violations))

    return {"lines": lines, "violations": violations, "passed": not violations}


def validate_rewrite_passage(raw_output, selection):
    """Format validation for a passage rewrite response."""
    text = strip_model_output(raw_output)
    violations = []
    if not text.strip():
        violations.append("empty")
        return {"text": text, "violations": violations, "passed": False}
    if normalize_suggestion_key(text) == normalize_suggestion_key(selection):
        violations.append("unchanged")
    if _MARKDOWN_RE.search(text):
        violations.append("markdown")
    if CONTROL_MARKER_RE.search(text):
        violations.append("control_marker")
    stripped = text.strip()
    if len(stripped) >= 2 and stripped[0] in "\"'“”‘’" and stripped[-1] in "\"'“”‘’":
        violations.append("quoted")
    selection_lines = len([l for l in selection.split("\n") if l.strip()])
    output_lines = len([l for l in text.split("\n") if l.strip()])
    if selection_lines > 1 and output_lines != selection_lines:
        violations.append("line_count_mismatch")
    for line in text.split("\n"):
        if PROMPT_ECHO_RE.search(line.strip()):
            violations.append("prompt_echo")
            break
    return {"text": text, "violations": violations, "passed": not violations}


def is_known_single_word(word, dictionary=None):
    """AIService.isKnownSingleWord (Android) / LexicalWordValidator.isKnownSpelling
    (iOS): both apps drop a local single-word result unless its lowercased
    spelling is exactly the dictionary key and the CMU dictionary knows it."""
    key = word.strip().lower()
    return (
        len(word) <= 32
        and is_single_word(word)
        and bool(key)
        and key == normalize_word(word)
        and bool((dictionary or shared_dictionary()).pronunciations(key))
    )


def validate_single_word_rewrite(raw_output, selection, rejected=()):
    """Format validation for a single-word rewrite response."""
    text = strip_model_output(raw_output)
    violations = []
    word = text.strip()
    if not word:
        violations.append("empty")
        return {"word": "", "violations": violations, "passed": False}
    if not is_single_word(word):
        violations.append("not_exactly_one_word")
    elif not is_known_single_word(word):
        violations.append("unknown_word")
    original_key = normalize_suggestion_key(selection)
    candidate_key = normalize_suggestion_key(word)
    if candidate_key == original_key:
        violations.append("same_as_original")
    rejected_keys = {
        normalize_suggestion_key(r) for r in rejected if normalize_suggestion_key(r)
    }
    if candidate_key in rejected_keys:
        violations.append("in_rejected_list")
    return {"word": word, "violations": violations, "passed": not violations}


def validate_synonyms(raw_output, target_word, limit):
    """Format validation for a synonyms response: one word per line."""
    text = strip_model_output(raw_output)
    lines = [l.strip() for l in text.split("\n") if l.strip()]
    violations = []
    if not lines:
        violations.append((-1, ["empty"]))
    if len(lines) > limit:
        violations.append((-1, ["more_than_%d_lines" % limit]))
    target_key = normalize_suggestion_key(target_word)
    seen = set()
    for index, line in enumerate(lines):
        line_violations = []
        if LIST_PREFIX_RE.search(line):
            line_violations.append("numbering_or_bullet")
        if not is_single_word(line):
            line_violations.append("not_single_word")
        elif not is_known_single_word(line):
            line_violations.append("unknown_word")
        key = normalize_suggestion_key(line)
        if key == target_key:
            line_violations.append("is_target_word")
        if key in seen:
            line_violations.append("duplicate")
        seen.add(key)
        if PROMPT_ECHO_RE.search(line):
            line_violations.append("prompt_echo")
        if line_violations:
            violations.append((index, line_violations))
    return {"words": lines, "violations": violations, "passed": not violations}
