"""Unchanged grading definitions extracted from the 2026-10-08 levels package.

Source grade_scheme.py SHA-256: 61aa8324a5d2403781b9ff7e977d6d1080443fb34a809ce0ad53dfe27b37d5fb
Only the grading dependency closure is retained; training/server helpers are omitted.
"""

from pathlib import Path

def load_dictionary(path):
    entries = {}
    for row in Path(path).read_text(encoding='utf-8').split('\n'):
        row = row.rstrip('\r')
        if not row or row.startswith('#') or '\t' not in row:
            continue
        word, _, rest = row.partition('\t')
        variants = [v.split() for v in rest.split('|')]
        variants = [v for v in variants if v]
        if variants:
            entries[word] = variants
    return entries


VOWELS = frozenset(['AA', 'AE', 'AH', 'AO', 'AW', 'AY', 'EH', 'ER', 'EY', 'IH', 'IY',
                    'OW', 'OY', 'UH', 'UW'])


def normalize_word(word):
    """Port of ProsodyAnalyzer.normalizeWord, ProsodyAnalyzer.swift:565-570.

    Lowercase, keep only a-z and the straight apostrophe (U+0027), then trim
    apostrophes from both ends. Typographic apostrophes are dropped, exactly
    as the app drops them.
    """
    kept = ''.join(ch for ch in word.lower() if 'a' <= ch <= 'z' or ch == "'")
    return kept.strip("'")


def line_end_word(line):
    """Port of RhymeConstraint.lineEndWord (iOS), RhymeConstraint.swift:15-23.

    Last whitespace-separated token whose normalized form is non-empty.
    """
    for token in reversed(line.split()):
        normalized = normalize_word(token)
        if normalized:
            return normalized
    return ''


def _base_phone(phone):  # ProsodyAnalyzer.swift:572-574
    return phone[:-1] if phone and phone[-1] in '012' else phone


def _stress(phone):  # ProsodyAnalyzer.swift:576-581
    return int(phone[-1]) if phone and phone[-1] in '012' else None


def rhyme_keys_for_phones(phones, max_depth):
    """Port of ProsodyAnalyzer.rhymeKeysForPhones, ProsodyAnalyzer.swift:682-691."""
    vowel_indexes = [i for i, p in enumerate(phones) if _base_phone(p) in VOWELS]
    if not vowel_indexes:
        return []
    stressed = [i for i in vowel_indexes if (_stress(phones[i]) or 0) > 0]
    anchors = stressed if stressed else vowel_indexes
    chosen = anchors[-max_depth:] if max_depth > 0 else []
    return [' '.join(_base_phone(p) for p in phones[i:]) for i in reversed(chosen)]


_INFLECTION_SUFFIXES = frozenset(['s', 'es', "'s", 'ed', 'ing'])


FUNCTION_WORDS = frozenset("""the a an and or but is are was were be to of in on at by for with as it its this that
these those i you he she we they them his her our their my do does did have has had not if so no
me mine myself your yours yourself yourselves him himself hers herself itself us ours ourselves theirs themselves
who whom whose which what whatever whoever whichever when whenever where wherever why how however whether
while whereas though although because unless then than yet nor there here some any each every either neither
both all such more most much many few less least into onto from upon unto via per among amongst toward
towards during until till since despite except against between through within without across am been being
having will would shall should can could may might must ought just very too also really quite rather else
i'm you're he's she's it's we're they're i've you've we've they've i'd you'd he'd she'd we'd they'd i'll
you'll he'll she'll we'll they'll isn't aren't wasn't weren't don't doesn't didn't won't wouldn't can't couldn't
shouldn't that's there's what's who's let's ain't""".split())


def is_inflection(word, base):
    """Port of ProsodyAnalyzer.isInflection, ProsodyAnalyzer.swift:624-630."""
    if not base or len(word) <= len(base):
        return False
    stems = [base, base[:-1]] if base.endswith('e') else [base]
    return any(word.startswith(stem) and word[len(stem):] in _INFLECTION_SUFFIXES for stem in stems)


STOPWORDS = frozenset("""the a an and or but is are was were be to of in on at by for with as it its this that
these those i you he she we they them his her our their my do does did have has had not if so no""".split())
