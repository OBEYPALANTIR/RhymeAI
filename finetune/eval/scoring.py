"""Scoring / phonetics for the RhymeAI local-model eval harness.

# PARITY
Ports of the Android sources (do not let these drift):
  - android/.../util/ProsodyAnalyzer.kt   (normalizeWord, rhymeKeys, findRhymes,
                                            syllable counting, PronunciationDictionary)
  - android/.../util/RhymeConstraint.kt   (lineEndWord, candidateEndWords, rhymeTier)
  - android/.../util/WordFrequency.kt     (frequency-rank re-sort of rhyme pools)
  - android/.../util/SyllableCounter.kt   (dictionary-first with heuristic fallback)
  - android/.../service/AIService.kt      (output-cleaning regexes used as validators)

The iOS-specific rhyme relation scorer mirrors
`Writers Block/Services/ProsodyAnalyzer.swift` because iOS keeps PERFECT, NEAR,
and SLANT acceptance exclusive while Android currently ranks NEAR and SLANT
with its shared loose tier.

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

# LyricTokenizer.wordPattern
WORD_PATTERN = re.compile(r"[a-zA-Z']+")

_STRESS_SUFFIX = re.compile(r"[0-2]$")


def normalize_word(word: str) -> str:
    """ProsodyAnalyzer.normalizeWord: lowercase, keep [a-z'], trim apostrophes."""
    kept = "".join(ch for ch in word.lower() if ("a" <= ch <= "z") or ch == "'")
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
    def __init__(self, perfect, near, multi):
        self.perfect = perfect
        self.near = near
        self.multi = multi

    @property
    def is_empty(self):
        return not (self.perfect or self.near or self.multi)


EMPTY_MATCHES = RhymeMatches([], [], [])

_index_built_for = None
_perfect_by_key = {}
_multi_by_key = {}
_near_by_vowel = {}


def _ensure_index(dictionary):
    global _index_built_for, _perfect_by_key, _multi_by_key, _near_by_vowel
    if _index_built_for is dictionary:
        return
    perfect_build = {}
    multi_build = {}
    near_build = {}
    for word, variants in dictionary.entries.items():
        if len(word) < 2 or word in STOPWORDS:
            continue
        seen_k0 = set()
        seen_k1 = set()
        seen_vowel = set()
        for phones in variants:
            ks = rhyme_keys_for_phones(phones, 2)
            if not ks:
                continue
            k0 = ks[0]
            if k0 not in seen_k0:
                seen_k0.add(k0)
                perfect_build.setdefault(k0, []).append(word)
            v0 = k0.split(" ")[0] if k0 else ""
            if v0 and v0 not in seen_vowel:
                seen_vowel.add(v0)
                near_build.setdefault(v0, []).append(word)
            if len(ks) < 2:
                continue
            k1 = ks[1]
            if k1 not in seen_k1:
                seen_k1.add(k1)
                multi_build.setdefault(k1, []).append(word)
    _perfect_by_key = perfect_build
    _multi_by_key = multi_build
    _near_by_vowel = near_build
    _index_built_for = dictionary


def find_rhymes(word, perfect_limit=60, near_limit=30, multi_limit=30,
                dictionary=None, word_frequency=None):
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
    vowel0 = k0.split(" ")[0] if k0 else ""
    if not vowel0.strip():
        return EMPTY_MATCHES

    _ensure_index(dictionary)
    perfect_all = [w for w in _perfect_by_key.get(k0, []) if w != normalized]
    if k1 is not None:
        perfect_set_pre = set(perfect_all)
        multi_all = [
            w for w in _multi_by_key.get(k1, [])
            if w != normalized and w not in perfect_set_pre
        ]
    else:
        multi_all = []
    perfect_set = set(perfect_all)
    multi_set = set(multi_all)
    near_all = [
        w for w in _near_by_vowel.get(vowel0, [])
        if w != normalized and w not in perfect_set and w not in multi_set
    ]

    return RhymeMatches(
        perfect=word_frequency.sort_by_frequency(perfect_all)[:perfect_limit],
        near=word_frequency.sort_by_frequency(near_all)[:near_limit],
        multi=word_frequency.sort_by_frequency(multi_all)[:multi_limit],
    )


def line_end_word(line):
    """RhymeConstraint.lineEndWord."""
    matches = WORD_PATTERN.findall(line)
    if not matches:
        return ""
    return normalize_word(matches[-1])


def candidate_end_words(target_word, rhyme_type, limit=12, dictionary=None):
    """RhymeConstraint.candidateEndWords. rhyme_type: 'PERFECT'|'NEAR'|'SLANT'."""
    dictionary = dictionary or shared_dictionary()
    matches = find_rhymes(target_word, dictionary=dictionary)
    if matches.is_empty:
        return []
    if rhyme_type == "PERFECT":
        pools = [matches.perfect, matches.multi]
    else:  # NEAR, SLANT
        pools = [matches.perfect, matches.multi, matches.near]
    normalized_target = normalize_word(target_word)
    ordered = []
    seen = set()
    for pool in pools:
        for word in pool:
            if word != normalized_target and word not in seen:
                seen.add(word)
                ordered.append(word)
    return ordered[:limit]


def rhyme_tier(line, matches):
    """RhymeConstraint.rhymeTier: 2 = perfect/multi, 1 = near, 0 = miss."""
    end_word = line_end_word(line)
    if not end_word:
        return 0
    if end_word in matches.perfect or end_word in matches.multi:
        return 2
    if end_word in matches.near:
        return 1
    return 0


def _rhyme_tail_for_phones(phones):
    vowel_indexes = [
        index for index, phone in enumerate(phones) if base_phone(phone) in VOWELS
    ]
    if not vowel_indexes:
        return None
    stressed = [index for index in vowel_indexes if (stress_for_phone(phones[index]) or 0) > 0]
    vowel_index = (stressed or vowel_indexes)[-1]
    return (
        base_phone(phones[vowel_index]),
        tuple(base_phone(phone) for phone in phones[vowel_index + 1:]),
    )


def _has_single_coda_edit(lhs, rhs):
    difference = len(lhs) - len(rhs)
    if abs(difference) > 1:
        return False
    if difference == 0:
        return sum(left != right for left, right in zip(lhs, rhs)) == 1
    shorter, longer = (lhs, rhs) if len(lhs) < len(rhs) else (rhs, lhs)
    short_index = 0
    skipped = False
    for phone in longer:
        if short_index < len(shorter) and shorter[short_index] == phone:
            short_index += 1
        elif skipped:
            return False
        else:
            skipped = True
    return short_index == len(shorter)


def _ios_rhyme_tier(line, target_word, dictionary):
    candidate = normalize_word(line_end_word(line))
    target = normalize_word(target_word)
    target_pronunciations = dictionary.pronunciations(target)
    if candidate == target or not target_pronunciations:
        return 0
    target_phones = target_pronunciations[0]
    target_keys = rhyme_keys_for_phones(target_phones, 2)
    target_tail = _rhyme_tail_for_phones(target_phones)
    if not target_keys or target_tail is None:
        return 0
    target_key = target_keys[0]
    target_multi_key = target_keys[1] if len(target_keys) > 1 else None
    near = False
    slant = False
    for candidate_phones in dictionary.pronunciations(candidate):
        candidate_keys = rhyme_keys_for_phones(candidate_phones, 2)
        if (
            (candidate_keys and candidate_keys[0] == target_key)
            or (
                target_multi_key is not None
                and len(candidate_keys) > 1
                and candidate_keys[1] == target_multi_key
            )
        ):
            return 2
        candidate_tail = _rhyme_tail_for_phones(candidate_phones)
        if candidate_tail is None:
            continue
        if (
            candidate_tail[0] == target_tail[0]
            and _has_single_coda_edit(target_tail[1], candidate_tail[1])
        ):
            near = True
        elif (
            target_tail[1]
            and candidate_tail[0] != target_tail[0]
            and candidate_tail[1] == target_tail[1]
        ):
            slant = True
    if near:
        return 1
    if slant:
        return 3
    return 0


def rhyme_tier_for_platform(line, target_word, platform, matches):
    if platform == "ios":
        return _ios_rhyme_tier(line, target_word, shared_dictionary())
    return rhyme_tier(line, matches)


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
CONTROL_MARKER_RE = re.compile(
    r"<?/?(?:start_of_turn|end_of_turn)>?\w*|_?response>|_?model_response>|"
    r"assistant_response>|model_response>|<\|turn>|<turn\|>|"
    r"<\|end_of_turn\|?>|<end_of_turn\|>",
    re.IGNORECASE,
)
HTML_MARKUP_RE = re.compile(r"</?[a-z][^>]*>", re.IGNORECASE)
SINGLE_WORD_RE = re.compile(r"(?:[^\W_]|['-])+$", re.UNICODE)
LEXICAL_SPELLING_RE = re.compile(r"^[a-z]+(?:['-][a-z]+)*$")
_NORMALIZE_KEY_RE = re.compile(r"[^a-z0-9]+")
_MARKDOWN_RE = re.compile(r"(```|\*\*|__|^#+\s)", re.MULTILINE)


def normalize_suggestion_key(text):
    """AIService.normalizeSuggestionKey."""
    return _NORMALIZE_KEY_RE.sub("", text.lower().strip())


def is_single_word(text):
    """AIService.isSingleWordSelection."""
    return bool(SINGLE_WORD_RE.fullmatch(text.strip()))


def lexical_spelling(text):
    return text.strip().lower().replace("’", "'")


def rejection_key(text):
    return lexical_spelling(text).replace("-", "").replace("'", "")


def is_lexically_valid(text, dictionary=None):
    spelling = lexical_spelling(text)
    if not LEXICAL_SPELLING_RE.fullmatch(spelling):
        return False
    dictionary = dictionary or shared_dictionary()
    return spelling in dictionary.entries


def word_count(line):
    return len([w for w in line.split() if w.strip()])


def strip_model_output(raw):
    """Light port of stripLocalModelArtifacts: cut control markers, fences."""
    text = raw.strip()
    # Drop anything up to and including a "model turn" marker the model echoed.
    payload = re.match(
        r".*(?:<start_of_turn>\s*model|start_of_turn>\s*model|_?model_response>|"
        r"assistant_response>|model_response>)\s*",
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


def _raw_output_violations(raw_output):
    violations = []
    if CONTROL_MARKER_RE.search(raw_output):
        violations.append("control_marker")
    if HTML_MARKUP_RE.search(raw_output):
        violations.append("html_markup")
    if _MARKDOWN_RE.search(raw_output):
        violations.append("markdown")
    return violations


def validate_suggestions(raw_output, expected_count, lyrics):
    """Format validation for a suggestions response.

    Returns dict: lines, violations (list of (line_index, [violation,...])),
    passed (bool).
    """
    text = strip_model_output(raw_output)
    lines = [l for l in text.split("\n") if l.strip()]
    violations = []
    raw_violations = _raw_output_violations(raw_output)
    if raw_violations:
        violations.append((-1, raw_violations))

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
    violations = _raw_output_violations(raw_output)
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


def validate_single_word_rewrite(raw_output, selection, rejected=()):
    """Format validation for a single-word rewrite response."""
    text = strip_model_output(raw_output)
    violations = _raw_output_violations(raw_output)
    word = text.strip()
    if not word:
        violations.append("empty")
        return {"word": "", "violations": violations, "passed": False}
    if not is_single_word(word):
        violations.append("not_exactly_one_word")
    original_key = normalize_suggestion_key(selection)
    candidate_key = normalize_suggestion_key(word)
    if candidate_key == original_key:
        violations.append("same_as_original")
    if not is_lexically_valid(word):
        violations.append("invalid_lexical_spelling")
    rejected_keys = {rejection_key(r) for r in rejected if rejection_key(r)}
    if rejection_key(word) in rejected_keys:
        violations.append("in_rejected_list")
    return {"word": word, "violations": violations, "passed": not violations}


def validate_synonyms(raw_output, target_word, limit):
    """Format validation for a synonyms response: one word per line."""
    text = strip_model_output(raw_output)
    lines = [l.strip() for l in text.split("\n") if l.strip()]
    violations = []
    raw_violations = _raw_output_violations(raw_output)
    if raw_violations:
        violations.append((-1, raw_violations))
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
        if not is_lexically_valid(line):
            line_violations.append("invalid_lexical_spelling")
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
