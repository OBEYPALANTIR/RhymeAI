"""Local-model prompt builders for the RhymeAI eval harness.

# PARITY
These functions mirror the Android app's prompt construction and MUST NOT
drift. Sources of truth (Kotlin):
  - android/.../service/AIService.kt
      buildLocalPrompt, buildLocalRewritePrompt, buildLocalSynonymsPrompt,
      constraintInstruction, buildSectionDirective, firstChorusLines,
      firstChorusEndWords, localLyricsContext, gemmaInstructionPrompt,
      suggestionRhymeConstraint, SUGGESTION_COUNT
  - android/.../data/model/RewriteAction.kt   (label + instruction strings)
  - android/.../data/model/SongSection.kt     (displayName + promptHint)
  - android/.../data/model/RhymeScheme.kt     (RhymeType / RhymeComplexity strings)
  - android/.../util/SectionMap.kt            (section parsing for directives)

Every string below is a byte-for-byte port. If a prompt changes in
AIService.kt, change it here in the same commit or the eval is meaningless.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import List, Optional, Sequence

from . import scoring

# ---------------------------------------------------------------------------
# Constants (AIService companion object)
# ---------------------------------------------------------------------------

SUGGESTION_COUNT = 6
LOCAL_RECENT_CONTEXT_CHARS = 2600
LOCAL_WHOLE_SONG_HEAD_CHARS = 900
LOCAL_WHOLE_SONG_TAIL_CHARS = 2200
SYNONYM_LIMIT_DEFAULT = 8  # AIService.getSynonyms(limit: Int = 8)

# ---------------------------------------------------------------------------
# Enum data (SongSection.kt, RhymeScheme.kt, RewriteAction.kt)
# ---------------------------------------------------------------------------

# SongSection: name -> (displayName, promptHint)
SONG_SECTIONS = {
    "VERSE": (
        "Verse",
        "Section direction: write it like a verse. Advance the narrative with concrete details, cause-and-effect, and a clear speaker perspective.",
    ),
    "CHORUS": (
        "Chorus",
        "Section direction: write it like a chorus or hook. Make it memorable, compact, repeatable, and emotionally direct without sounding like a slogan.",
    ),
    "BRIDGE": (
        "Bridge",
        "Section direction: write it like a bridge. Create a harmonic or emotional turn, add contrast, and set up a satisfying return.",
    ),
    "UNKNOWN": (
        "Unmarked section",
        "Section direction: no verse, chorus, or bridge header was detected. Fit the immediate stanza and surrounding lyric context.",
    ),
}

# RhymeType: name -> displayName
RHYME_TYPES = {
    "PERFECT": "Perfect Rhyme",
    "NEAR": "Near Rhyme",
    "SLANT": "Slant Rhyme",
}

# RhymeComplexity: name -> (label, promptHint)
RHYME_COMPLEXITIES = {
    "SIMPLE": (
        "Simple",
        "Use simple, everyday vocabulary. Keep the language accessible and straightforward. Aim for clear, easy-to-understand rhymes.",
    ),
    "MODERATE": (
        "Moderate",
        "Use a balanced vocabulary with some clever wordplay. The rhymes should be interesting but not overly complex.",
    ),
    "COMPLEX": (
        "Complex",
        "Use advanced, rich vocabulary with intricate multi-syllable rhymes, internal rhymes, and sophisticated wordplay. Push the boundaries of lyrical complexity.",
    ),
}

# RewriteAction: name -> (label, instruction)
REWRITE_ACTIONS = {
    "REPHRASE": (
        "Rephrase",
        "Rewrite this passage using different wording while preserving the exact meaning and tone. Keep roughly the same syllable count and the same rhyme positions at the end of each line.",
    ),
    "HARDER_RHYME": (
        "Harder Rhyme",
        "Rewrite this passage so the last word of each line forms a stronger rhyme with the prior line's ending word. Preserve meaning and meter. Prefer multi-syllable rhymes where they fit.",
    ),
    "PUNCH_UP": (
        "Punch Up",
        "Rewrite this passage with sharper, more visceral, and more aggressive imagery. Preserve meaning and rhyme positions. Avoid clichés. Hit harder.",
    ),
}


def section_from_header(header: str) -> str:
    """SongSection.fromHeader."""
    normalized = header.strip().lstrip("[").rstrip("]").strip().lower()
    squashed = normalized.replace("-", "").replace(" ", "")
    if "verse" in normalized:
        return "VERSE"
    if "bridge" in normalized:
        return "BRIDGE"
    if "hook" in normalized:
        return "CHORUS"
    if "chorus" in normalized and "prechorus" not in squashed:
        return "CHORUS"
    return "UNKNOWN"


# ---------------------------------------------------------------------------
# SectionMap (SectionMap.kt)
# ---------------------------------------------------------------------------

@dataclass
class SectionRef:
    type: str          # SongSection name
    ordinal: int       # 1-based per type
    label: str
    line_range: range  # half-open [first, last)


_BRACKETED_HEADER = re.compile(r"^\s*\[(.+)]\s*$")
_BARE_HEADER = re.compile(
    r"^(verse|chorus|hook|bridge|pre[- ]?chorus|intro|outro)(\s+\d+)?$",
    re.IGNORECASE,
)


def parse_section_map(lyrics: str) -> List[SectionRef]:
    lines = lyrics.split("\n")

    headers = []  # (line_index, label)
    for idx, line in enumerate(lines):
        trimmed = line.strip()
        bracketed = _BRACKETED_HEADER.match(line)
        if bracketed:
            headers.append((idx, bracketed.group(1).strip()))
            continue
        if trimmed and _BARE_HEADER.fullmatch(trimmed):
            headers.append((idx, trimmed))

    ordinal_counter = {}
    refs = []

    implicit_end = headers[0][0] if headers else len(lines)
    refs.append(SectionRef("UNKNOWN", 1, "Intro", range(0, implicit_end)))

    for i, (line_index, label) in enumerate(headers):
        section_type = section_from_header(label)
        ordinal = ordinal_counter.get(section_type, 0) + 1
        ordinal_counter[section_type] = ordinal
        range_end = headers[i + 1][0] if i + 1 < len(headers) else len(lines)
        refs.append(SectionRef(section_type, ordinal, label, range(line_index, range_end)))

    filtered = refs[1:] if len(refs[0].line_range) == 0 else refs
    if not filtered:
        return [SectionRef("UNKNOWN", 1, "Intro", range(0, len(lines)))]
    return filtered


def section_at(refs: List[SectionRef], line_index: int) -> SectionRef:
    """SectionMap.sectionAt."""
    for ref in reversed(refs):
        if line_index >= ref.line_range.start:
            return ref
    return refs[0]


# ---------------------------------------------------------------------------
# Suggestion rhyme constraint (AIService.suggestionRhymeConstraint)
# ---------------------------------------------------------------------------

@dataclass
class SuggestionRhymeConstraint:
    target_line: str
    target_word: str
    candidate_words: List[str]
    rhyme_type: str  # RhymeType name
    section_ref: Optional[SectionRef] = None
    chorus_end_words: frozenset = field(default_factory=frozenset)
    # joinToString order matters: keep the ordered candidate list AND the
    # ordered chorus end-words for prompt-identical output.
    chorus_end_words_ordered: tuple = ()


_HEADER_LINE = re.compile(r"^\s*\[.+]\s*$")


def first_chorus_end_words(lyrics: str) -> List[str]:
    """AIService.firstChorusEndWords — normalized end-words of the first CHORUS
    section's lines, in document order (Kotlin builds a LinkedHashSet)."""
    refs = parse_section_map(lyrics)
    first_chorus = next((r for r in refs if r.type == "CHORUS"), None)
    if first_chorus is None:
        return []
    lines = lyrics.split("\n")
    seen = []
    for idx in first_chorus.line_range:
        if idx >= len(lines):
            continue
        end = scoring.line_end_word(lines[idx])
        if end and end not in seen:
            seen.append(end)
    return seen


def first_chorus_lines(lyrics: str) -> List[str]:
    """AIService.firstChorusLines — non-header, non-blank lines of first chorus."""
    refs = parse_section_map(lyrics)
    first_chorus = next((r for r in refs if r.type == "CHORUS"), None)
    if first_chorus is None:
        return []
    lines = lyrics.split("\n")
    result = []
    for idx in first_chorus.line_range:
        if idx >= len(lines):
            continue
        line = lines[idx]
        if line.strip() and not _HEADER_LINE.match(line):
            result.append(line)
    return result


def suggestion_rhyme_constraint(
    target_rhyme_line: Optional[str],
    rhyme_type: str,
    section_ref: Optional[SectionRef] = None,
    chorus_end_words: Sequence[str] = (),
) -> Optional[SuggestionRhymeConstraint]:
    """AIService.suggestionRhymeConstraint."""
    if target_rhyme_line is None or not target_rhyme_line.strip():
        return None
    target_word = scoring.line_end_word(target_rhyme_line)
    if not target_word:
        return None
    candidates = scoring.candidate_end_words(target_word, rhyme_type)
    if not candidates:
        return None

    section_type = section_ref.type if section_ref else "UNKNOWN"
    ordinal = section_ref.ordinal if section_ref else 1
    chorus_list = list(chorus_end_words)
    chorus_set = set(chorus_list)

    # Chorus repeat (2nd+): promote first-chorus end-words to the front.
    if section_type == "CHORUS" and ordinal >= 2 and chorus_list:
        promoted = [w for w in chorus_list if w != target_word and w in candidates]
        rest = [w for w in candidates if w not in promoted]
        candidates = promoted + rest

    # Verse and bridge: exclude the chorus's end-words unless that empties it.
    if section_type in ("VERSE", "BRIDGE") and chorus_list:
        filtered = [w for w in candidates if w not in chorus_set]
        if filtered:
            candidates = filtered

    return SuggestionRhymeConstraint(
        target_line=target_rhyme_line,
        target_word=target_word,
        candidate_words=candidates,
        rhyme_type=rhyme_type,
        section_ref=section_ref,
        chorus_end_words=frozenset(chorus_set),
        chorus_end_words_ordered=tuple(chorus_list),
    )


# ---------------------------------------------------------------------------
# Prompt fragments (AIService.kt)
# ---------------------------------------------------------------------------

def _constraint_instruction(constraint: SuggestionRhymeConstraint) -> str:
    """AIService.constraintInstruction."""
    return (
        'The new line must rhyme with: "%s" (it ends with "%s").\n'
        "End each line with one of these rhyming words: %s (choose the most natural fit)."
        % (
            constraint.target_line,
            constraint.target_word,
            ", ".join(constraint.candidate_words),
        )
    )


def _build_section_directive(ref: Optional[SectionRef], lyrics: str) -> str:
    """AIService.buildSectionDirective. Exact sentences are part of the
    iOS/Android prompt parity contract."""
    if ref is None:
        return ""
    if ref.type == "VERSE":
        return "This is Verse %d.\n" % ref.ordinal
    if ref.type == "BRIDGE":
        return (
            "This is the bridge — introduce a contrasting rhyme sound and cadence; "
            "avoid the chorus's ending words.\n"
        )
    if ref.type == "CHORUS":
        if ref.ordinal < 2:
            return ""
        chorus_lines = first_chorus_lines(lyrics)
        chorus_block = ("\n" + "\n".join(chorus_lines)) if chorus_lines else ""
        return (
            "This is the chorus (instance %d). Keep hook language and ending words "
            "consistent with the established chorus:%s\n" % (ref.ordinal, chorus_block)
        )
    return ""


def _trim_to_line_boundary(text: str, prefer_start: bool) -> str:
    """String.trimToLineBoundary."""
    if not text:
        return text
    if prefer_start:
        newline = text.find("\n")
        if 0 <= newline < len(text) - 1:
            return text[newline + 1:].strip()
        return text.strip()
    newline = text.rfind("\n")
    if newline > 0:
        return text[:newline].strip()
    return text.strip()


def local_lyrics_context(lyrics: str, use_whole_song_context: bool) -> str:
    """AIService.localLyricsContext."""
    trimmed = lyrics.strip()
    if len(trimmed) <= LOCAL_RECENT_CONTEXT_CHARS:
        return trimmed

    if use_whole_song_context:
        head = _trim_to_line_boundary(
            trimmed[:LOCAL_WHOLE_SONG_HEAD_CHARS], prefer_start=False
        )
        tail = _trim_to_line_boundary(
            trimmed[-LOCAL_WHOLE_SONG_TAIL_CHARS:], prefer_start=True
        )
        return "%s\n\n[Middle lyrics trimmed for on-device speed]\n\n%s" % (head, tail)
    return "[Earlier lyrics trimmed for on-device speed]\n" + _trim_to_line_boundary(
        trimmed[-LOCAL_RECENT_CONTEXT_CHARS:], prefer_start=True
    )


def gemma_instruction_prompt(user_prompt: str) -> str:
    """AIService.gemmaInstructionPrompt — the <start_of_turn> template.

    NOTE: Kotlin trimIndent() drops the trailing newline, so the prompt ends
    exactly with "<start_of_turn>model" (no trailing newline)."""
    return "<start_of_turn>user\n%s\n<end_of_turn>\n<start_of_turn>model" % user_prompt


# ---------------------------------------------------------------------------
# Public prompt builders
# ---------------------------------------------------------------------------

def build_suggestions_prompt(
    theme: str,
    lyrics: str,
    target_rhyme_line: Optional[str],
    rhyme_type: str,
    rhyme_scheme: str,
    current_letter: str,
    current_section: str = "UNKNOWN",
    complexity: str = "MODERATE",
    use_whole_song_context: bool = False,
    constraint: Optional[SuggestionRhymeConstraint] = None,
) -> str:
    """AIService.buildLocalPrompt, wrapped in the Gemma turn template."""
    rhyme_type_display = RHYME_TYPES[rhyme_type]
    section_display, section_hint = SONG_SECTIONS[current_section]
    complexity_label, complexity_hint = RHYME_COMPLEXITIES[complexity]

    if target_rhyme_line is not None:
        rhyme_hint = 'End every suggestion with a %s for: "%s".' % (
            rhyme_type_display.lower(),
            target_rhyme_line,
        )
    else:
        rhyme_hint = 'Start a new rhyme sound for letter "%s".' % current_letter

    constraint_block = ("\n" + _constraint_instruction(constraint)) if constraint else ""
    request_count = SUGGESTION_COUNT
    if use_whole_song_context:
        song_context_instruction = (
            "Use the whole-song context for story arc, recurring images, hook "
            "language, speaker perspective, tone, and vocabulary."
        )
    else:
        song_context_instruction = "Use the immediate stanza, rhyme target, and theme first."

    if theme.strip() and not use_whole_song_context:
        effective_theme = theme.strip()
    else:
        effective_theme = "Infer from the lyrics."

    lyric_context = local_lyrics_context(lyrics, use_whole_song_context)
    section_directive = _build_section_directive(
        constraint.section_ref if constraint else None, lyrics
    )

    user_prompt = (
        "You are RhymeAI's on-device songwriting assistant.\n"
        "\n"
        "Task: write exactly %d next-line options for the song.\n"
        "Theme: %s\n"
        'Rhyme scheme: "%s"; next line is "%s".\n'
        "Current song section: %s.\n"
        "%s\n"
        "%s%s%s\n"
        "%s\n"
        "Complexity: %s. %s\n"
        "\n"
        "Lyrics context:\n"
        '"""\n'
        "%s\n"
        '"""\n'
        "\n"
        "Rules:\n"
        "- Return exactly %d lines.\n"
        "- One suggestion per line.\n"
        "- Return only candidate lyric lines.\n"
        "- Do not copy any existing lyric line.\n"
        "- Do not repeat the same suggestion.\n"
        "- No numbering, bullets, quotes, markdown, labels, or explanation.\n"
        "- Do not apologize, explain limitations, or restate the rules.\n"
        "- Keep each suggestion under 16 words."
    ) % (
        request_count,
        effective_theme,
        rhyme_scheme,
        current_letter,
        section_display,
        section_hint,
        section_directive,
        rhyme_hint,
        constraint_block,
        song_context_instruction,
        complexity_label,
        complexity_hint,
        lyric_context,
        request_count,
    )
    return gemma_instruction_prompt(user_prompt)


def _rewrite_reject_keys(selection: str, rejected_candidates: Sequence[str]) -> List[str]:
    """AIService.rewriteRejectKeys — LinkedHashSet order: rejected first, then
    the selection's own key."""
    ordered = []
    for item in list(rejected_candidates) + [selection]:
        key = scoring.normalize_suggestion_key(item)
        if key and key not in ordered:
            ordered.append(key)
    return ordered


def _lyric_line_at(lyrics: str, selection_start: int) -> str:
    """AIService.lyricLineAt."""
    start = max(0, min(selection_start, len(lyrics)))
    line_start = lyrics.rfind("\n", 0, max(start - 1, 0) + 1)
    line_start = 0 if line_start < 0 else line_start + 1
    line_end = lyrics.find("\n", start)
    line_end = len(lyrics) if line_end < 0 else line_end
    return lyrics[line_start:line_end].strip()


def build_rewrite_prompt(
    action: str,
    lyrics: str,
    selection: str,
    current_section: str = "UNKNOWN",
    selection_start: Optional[int] = None,
    rejected_candidates: Sequence[str] = (),
) -> str:
    """AIService.buildLocalRewritePrompt — passage AND single-word variants."""
    action_label, action_instruction = REWRITE_ACTIONS[action]
    section_display, section_hint = SONG_SECTIONS[current_section]

    lyric_context = local_lyrics_context(lyrics, use_whole_song_context=False)
    single_word = scoring.is_single_word(selection)

    selected_line = None
    if selection_start is not None:
        line = _lyric_line_at(lyrics, selection_start)
        if line.strip():
            selected_line = line

    if single_word:
        task_line = "Task: replace the selected word with a different word that fits the song."
    else:
        task_line = "Task: rewrite the selected passage from the user's song."

    rejected_keys = _rewrite_reject_keys(selection, rejected_candidates)
    if single_word and rejected_keys:
        rejected_rule = "- Do not return any of these rejected words: %s." % ", ".join(rejected_keys)
    else:
        rejected_rule = ""

    if single_word:
        output_rules = (
            "- Return exactly one replacement word.\n"
            "- The replacement must be different from the selected word.\n"
            '- Do not return "%s".\n'
            "%s\n"
            "- No quotes, no markdown, no labels, no commentary."
        ) % (selection, rejected_rule)
    else:
        output_rules = (
            "- Output the rewritten passage only.\n"
            "- Preserve line breaks if the selection has multiple lines.\n"
            "- No quotes, no markdown, no labels, no commentary."
        )

    if selected_line is not None:
        selected_line_block = 'Line containing the selected word:\n"""\n%s\n"""\n' % selected_line
    else:
        selected_line_block = ""

    user_prompt = (
        "You are RhymeAI's on-device songwriting assistant.\n"
        "\n"
        "%s\n"
        "Current song section: %s.\n"
        "%s\n"
        "Action: %s.\n"
        "Instruction: %s\n"
        "\n"
        "Lyrics context:\n"
        '"""\n'
        "%s\n"
        '"""\n'
        "\n"
        "%s\n"
        "Selected passage to rewrite:\n"
        '"""\n'
        "%s\n"
        '"""\n'
        "\n"
        "Rules:\n"
        "%s"
    ) % (
        task_line,
        section_display,
        section_hint,
        action_label,
        action_instruction,
        lyric_context,
        selected_line_block,
        selection,
        output_rules,
    )
    return gemma_instruction_prompt(user_prompt)


def build_synonyms_prompt(word: str, line_context: str, limit: int = SYNONYM_LIMIT_DEFAULT) -> str:
    """AIService.buildLocalSynonymsPrompt. NOTE: the app calls this with
    word.trim() (see getSynonyms)."""
    context_line = line_context.strip()[:180]
    context_block = context_line if context_line else "(no surrounding line)"
    user_prompt = (
        "You are RhymeAI's on-device word helper.\n"
        "\n"
        'Task: give up to %d single-word replacements for "%s" in this lyric line:\n'
        '"%s"\n'
        "\n"
        "Rules:\n"
        "- Return only replacement words, one per line.\n"
        "- No JSON, bullets, numbering, labels, quotes, or commentary.\n"
        '- Do not include "%s".\n'
        "- Prefer words with similar tone and syllable count."
    ) % (limit, word, context_block, word)
    return gemma_instruction_prompt(user_prompt)


# ---------------------------------------------------------------------------
# Self-test: python3 -m eval.prompts  (run from finetune/)
# ---------------------------------------------------------------------------

def _self_test():
    lyrics = (
        "[Verse 1]\n"
        "I packed my bags before the morning light\n"
        "Left a note beside the kitchen door\n"
        "The engine hummed a promise to the night\n"
        "\n"
        "[Chorus]\n"
        "Take me down that open road\n"
        "Where the sky forgets my name\n"
        "Every mile a lighter load\n"
        "I am never going back the same\n"
        "\n"
        "[Verse 2]\n"
        "The radio keeps playing static songs\n"
        "Dust is dancing on the dashboard glow"
    )
    target_line = "Dust is dancing on the dashboard glow"
    refs = parse_section_map(lyrics)
    section_ref = next(r for r in refs if r.type == "VERSE" and r.ordinal == 2)
    chorus_ends = first_chorus_end_words(lyrics)
    constraint = suggestion_rhyme_constraint(
        target_line, "PERFECT", section_ref=section_ref, chorus_end_words=chorus_ends
    )

    print("=" * 72)
    print("SUGGESTIONS PROMPT (constrained, Verse 2, PERFECT, MODERATE)")
    print("=" * 72)
    print(build_suggestions_prompt(
        theme="leaving a small town",
        lyrics=lyrics,
        target_rhyme_line=target_line,
        rhyme_type="PERFECT",
        rhyme_scheme="ABAB",
        current_letter="B",
        current_section="VERSE",
        complexity="MODERATE",
        use_whole_song_context=False,
        constraint=constraint,
    ))

    print()
    print("=" * 72)
    print("REWRITE PROMPT (single word, HARDER_RHYME, with rejected words)")
    print("=" * 72)
    selection = "glow"
    selection_start = lyrics.rindex("glow")
    print(build_rewrite_prompt(
        action="HARDER_RHYME",
        lyrics=lyrics,
        selection=selection,
        current_section="VERSE",
        selection_start=selection_start,
        rejected_candidates=["shine", "spark"],
    ))

    print()
    print("=" * 72)
    print("REWRITE PROMPT (passage, PUNCH_UP)")
    print("=" * 72)
    passage = "Take me down that open road\nWhere the sky forgets my name"
    print(build_rewrite_prompt(
        action="PUNCH_UP",
        lyrics=lyrics,
        selection=passage,
        current_section="CHORUS",
    ))

    print()
    print("=" * 72)
    print("SYNONYMS PROMPT")
    print("=" * 72)
    print(build_synonyms_prompt("promise", "The engine hummed a promise to the night"))


if __name__ == "__main__":
    _self_test()
