"""Local-model prompt builders for the RhymeAI eval harness.

# PARITY
These functions mirror the Android app's prompt construction and MUST NOT
drift. Sources of truth (Kotlin):
  - android/.../service/AIService.kt
      buildLocalPrompt, buildLocalRewritePrompt, buildLocalSynonymsPrompt,
      constraintInstruction, buildSectionDirective, firstChorusLines,
      firstChorusEndWords, localLyricsContext,
      suggestionRhymeConstraint, SUGGESTION_COUNT
  - Writers Block/.../Services/GGUFModelService.swift
      GGUFPromptFormat.resolve, gemmaPrompt (the on-device turn envelope)
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
LOCAL_TRIM_MARKER = "[Lyrics trimmed for on-device speed]"
LOCAL_SUGGESTION_INTENT = (
    "The writer is stuck on the next line and wants ideas to pick from, not a finished verse."
)
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
        "Use plain, simple, everyday language. No wordplay, puns, or clever twists. Use clear rhymes that are easy to hear.",
    ),
    "MODERATE": (
        "Moderate",
        "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever.",
    ),
    "COMPLEX": (
        "Complex",
        "Use advanced, rich vocabulary with clever wordplay and intricate rhymes: multi-syllable rhymes, internal rhymes, and double meanings.",
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


def _utf16_len(text: str) -> int:
    """String length in UTF-16 code units (non-BMP scalars count 2)."""
    return len(text.encode("utf-16-le")) // 2


def _utf16_suffix(text: str, max_units: int) -> str:
    """Longest suffix of whole scalars that fits in `max_units` UTF-16 units;
    matches the platforms' cut, which skips a low surrogate at the cut point."""
    units = 0
    start = len(text)
    while start > 0:
        size = 2 if ord(text[start - 1]) > 0xFFFF else 1
        if units + size > max_units:
            break
        units += size
        start -= 1
    return text[start:]


def local_end_word_rule(allowed_words: Optional[Sequence[str]]) -> str:
    """AIService.localEndWordRule: a list with fewer than six distinct
    (case-folded) words cannot give six different endings, so repeats are allowed.
    Repeated chorus end words count once."""
    if allowed_words is None:
        return "- End each line on a different word."
    if len({w.lower() for w in allowed_words}) >= SUGGESTION_COUNT:
        return "- End each line on a different word from the allowed list."
    return "- The allowed list has fewer than six words, so end words may repeat, but the six lines must still be six different ideas."


def local_lyric_window(
    lyrics: str, cursor_line: Optional[int], budget: int, head_budget: int
) -> str:
    """AIService.localLyricWindow (same name and rule in AIService.kt and AIService.swift).

    Lyrics over `budget` characters keep, in order: the cursor's
    blank-line-delimited stanza plus the lines either side of the cursor; the
    opening lines up to `head_budget`; then the lines nearest that window,
    one above then one below, until the budget is spent. Each skipped run
    that holds a lyric becomes one marker line; room for two markers is
    reserved, so the result never exceeds `budget`. A stanza too long for the
    budget keeps only the cursor's neighbours before the nearest-line fill, and
    if those are still too long, only the cursor line. A cursor line longer
    than the budget keeps its end (where the next line is inserted) after a
    marker. Lengths count UTF-16 units, as String.length (Kotlin) and
    utf16.count (Swift) do, and a cut never splits a surrogate pair."""
    trimmed = lyrics.strip()
    if _utf16_len(trimmed) <= budget:
        return trimmed
    lines = lyrics.split("\n")
    last = len(lines) - 1
    c = last if cursor_line is None else min(max(cursor_line, 0), last)
    line_budget = budget - 2 * (len(LOCAL_TRIM_MARKER) + 1)

    def cost(i: int) -> int:
        return _utf16_len(lines[i]) + 1

    def blank(i: int) -> bool:
        return not lines[i].strip()

    block_start = next((i + 1 for i in range(c - 1, -1, -1) if blank(i)), 0)
    if blank(c):
        block_end = c
    else:
        block_end = next((i - 1 for i in range(c + 1, last + 1) if blank(i)), last)
    lo = min(block_start, max(c - 1, 0))
    hi = max(block_end, min(c + 1, last))
    if sum(cost(i) for i in range(lo, hi + 1)) > line_budget:
        lo, hi = max(c - 1, 0), min(c + 1, last)
    if sum(cost(i) for i in range(lo, hi + 1)) > line_budget:
        lo, hi = c, c
    cut = None
    if cost(c) > line_budget:
        cut = _utf16_suffix(lines[c], line_budget - 1)
        used = line_budget
    else:
        used = sum(cost(i) for i in range(lo, hi + 1))

    head_count = 0
    head_used = 0
    while head_count < lo and head_used + cost(head_count) <= head_budget and used + cost(head_count) <= line_budget:
        head_used += cost(head_count)
        used += cost(head_count)
        head_count += 1

    while True:
        grew = False
        if lo - 1 >= head_count and used + cost(lo - 1) <= line_budget:
            lo -= 1
            used += cost(lo)
            grew = True
        if hi + 1 <= last and used + cost(hi + 1) <= line_budget:
            hi += 1
            used += cost(hi)
            grew = True
        if not grew:
            break

    def has_lyric(a: int, b: int) -> bool:
        return any(not blank(i) for i in range(a, b))

    out = lines[:head_count]
    if has_lyric(head_count, lo) or cut is not None:
        out.append(LOCAL_TRIM_MARKER)
    out.extend(cut if cut is not None and i == c else lines[i] for i in range(lo, hi + 1))
    if has_lyric(hi + 1, last + 1):
        out.append(LOCAL_TRIM_MARKER)
    return "\n".join(out).strip()


def local_lyrics_context(
    lyrics: str, use_whole_song_context: bool, cursor_line: Optional[int] = None
) -> str:
    """AIService.localLyricsContext."""
    if use_whole_song_context:
        return local_lyric_window(
            lyrics,
            cursor_line,
            LOCAL_WHOLE_SONG_HEAD_CHARS + LOCAL_WHOLE_SONG_TAIL_CHARS,
            LOCAL_WHOLE_SONG_HEAD_CHARS,
        )
    return local_lyric_window(lyrics, cursor_line, LOCAL_RECENT_CONTEXT_CHARS, 0)


# ---------------------------------------------------------------------------
# On-device prompt envelope
# ---------------------------------------------------------------------------
# The builders below return the INNER prompt; the app adds the turn markers
# for the loaded model's family in exactly one place. Mirror of
# "Writers Block/Writers Block/Services/GGUFModelService.swift":
#   GGUFPromptFormat.resolve      lines 339-350 (family from GGUF metadata)
#   GGUFModelService.gemmaPrompt  lines 469-491 (the envelope bytes)
# llama.cpp prepends <bos> itself (llama_tokenize with addSpecialTokens,
# lines 434 and 720; the GGUFs set tokenizer.ggml.add_bos_token), so an
# envelope never contains <bos>, and parseSpecialTokens maps each marker to
# its single special token. The model ends its turn by emitting
# `end_of_turn`, an end-of-generation token. Android renders the same bytes
# from the GGUF's own chat template (LocalModelService.formatPrompt), which
# additionally trims the content.
# The shipped RhymeAI E2B/E4B GGUFs are general.architecture "gemma4" with a
# <|turn>/<turn|> chat template, so the app always gives them GEMMA4.


@dataclass(frozen=True)
class PromptEnvelope:
    name: str          # GGUFModelService's tokenizerEnvelope spelling
    user_marker: str
    model_marker: str
    suffix: str        # appended after model_marker
    end_of_turn: str

    @property
    def generation_prefix(self) -> str:
        """The model-turn opener the app's prompt ends with."""
        return self.model_marker.rsplit("\n", 1)[-1] + self.suffix


GEMMA4 = PromptEnvelope(
    "gemma4", "<|turn>user\n", "<turn|>\n<|turn>model", "\n", "<turn|>")
GEMMA_LEGACY = PromptEnvelope(
    "gemmaLegacy", "<start_of_turn>user\n", "\n<end_of_turn>\n<start_of_turn>model",
    "", "<end_of_turn>")
ENVELOPES = {envelope.name: envelope for envelope in (GEMMA4, GEMMA_LEGACY)}
# --envelope values shared by prepare_dataset.py, run_eval.py and generate.py.
ENVELOPE_OPTIONS = {"gemma4": GEMMA4, "legacy": GEMMA_LEGACY}
# The builders return the inner prompt, which never carries these.
TURN_MARKERS = ("<start_of_turn>", "<end_of_turn>", "<|turn>", "<turn|>")


def template_envelope(chat_template: str) -> Optional[PromptEnvelope]:
    """The envelope whose markers a chat template uses: the template half of
    GGUFPromptFormat.resolve. None when it has neither or both."""
    has_legacy = "<start_of_turn>" in chat_template and "<end_of_turn>" in chat_template
    has_gemma4 = "<|turn>" in chat_template and "<turn|>" in chat_template
    if has_gemma4 == has_legacy:
        return None
    return GEMMA4 if has_gemma4 else GEMMA_LEGACY


def resolve_prompt_envelope(architecture: str, chat_template: str) -> Optional[PromptEnvelope]:
    """GGUFPromptFormat.resolve; None means the app refuses the model."""
    envelope = template_envelope(chat_template)
    if architecture == "gemma4":
        return envelope if envelope is GEMMA4 else None
    if architecture in ("gemma", "gemma2", "gemma3", "gemma3n"):
        return envelope if envelope is GEMMA_LEGACY else None
    return None


def app_prompt(user_prompt: str, envelope: PromptEnvelope = GEMMA4) -> str:
    """GGUFModelService.gemmaPrompt: the exact text the app tokenizes."""
    content = user_prompt
    while content.startswith(envelope.user_marker):
        normalized = (content[:-1] if content.endswith(envelope.model_marker + "\n")
                      else content)
        if not normalized.endswith(envelope.model_marker):
            break
        content = normalized[len(envelope.user_marker):-len(envelope.model_marker)]
    return envelope.user_marker + content + envelope.model_marker + envelope.suffix


# ---------------------------------------------------------------------------
# Public prompt builders. Each returns the INNER prompt, as AIService does;
# a raw-text request wraps it with app_prompt, as the app's runner does.
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
    cursor_line: Optional[int] = None,
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

    if theme.strip():
        effective_theme = theme.strip()
    else:
        effective_theme = "Infer from the lyrics."

    lyric_context = local_lyrics_context(lyrics, use_whole_song_context, cursor_line)
    section_directive = _build_section_directive(
        constraint.section_ref if constraint else None, lyrics
    )
    end_word_rule = local_end_word_rule(constraint.candidate_words if constraint else None)

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
        "- Make the six lines six different directions: a different idea, image or angle in each. Do not write the same thought six ways.\n"
        "%s\n"
        "- Write them as raw material in the writer's own voice: match the length, plainness and capitalisation of the lines around it.\n"
        "- Do not resolve or conclude the song, do not sum it up, and no grand statements.\n"
        "- Stay inside what the song is already about.\n"
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
        LOCAL_SUGGESTION_INTENT,
        song_context_instruction,
        complexity_label,
        complexity_hint,
        lyric_context,
        request_count,
        end_word_rule,
    )
    return user_prompt


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
    return user_prompt


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
    return user_prompt


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
