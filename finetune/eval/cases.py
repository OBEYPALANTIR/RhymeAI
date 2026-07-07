"""Eval cases for the RhymeAI local-model harness.

All lyric contexts below are original placeholder lyrics written for this
harness — they are NOT real song lyrics.

Case schema (dict):
  id: unique string
  task: "suggestions" | "rewrite_passage" | "rewrite_word" | "synonyms"

  suggestions:
    theme, lyrics, target_rhyme_line (str or None), rhyme_type
    ("PERFECT"|"NEAR"|"SLANT"), rhyme_scheme, current_letter,
    section (tuple (type, ordinal) or None -> SectionRef lookup),
    current_section (SongSection name), complexity, use_whole_song_context

  rewrite_passage / rewrite_word:
    action ("REPHRASE"|"HARDER_RHYME"|"PUNCH_UP"), lyrics, selection,
    current_section, selection_word (rewrite_word only: locate selection_start),
    rejected (list of rejected candidate words, rewrite_word only)

  synonyms:
    word, line_context, limit
"""

# ---------------------------------------------------------------------------
# Placeholder lyric contexts (original, written for this harness)
# ---------------------------------------------------------------------------

SONG_ROAD = """[Verse 1]
I packed my bags before the morning light
Left a note beside the kitchen door
The engine hummed a promise to the night
Told the gravel I don't live here anymore

[Chorus]
Take me down that open road
Where the sky forgets my name
Every mile a lighter load
I am never going back the same

[Verse 2]
The radio keeps playing static songs
Dust is dancing on the dashboard glow"""

SONG_EMBER = """[Verse 1]
The furnace in the basement finally died
We wore our winter coats around the house
You drew a little sun on the frosted glass inside

[Chorus]
Keep one ember burning low
Something warm to guide us home
When the power lines are down
We will make it on our own

[Bridge]
All the maps we drew are set in stone"""

SONG_CITY = """[Verse 1]
Concrete rivers running past my door
Neon puddles shining on the ground
I count the windows lit on every floor

[Chorus]
We are running on a live wire
Every heartbeat taking us higher
Hearts lit up like a signal fire
Never letting go of this desire

[Verse 2]
The subway hums a lullaby below
Strangers trade their shadows in the rain

[Chorus]
We are running on a live wire"""

SONG_PLAIN = """The clouds rolled in without a warning sign
I watched the thunder practice in the rain
The porch light flickered like a nervous spark
And every window rattled with the strain"""

SONG_GARDEN = """[Verse 1]
Grandma kept her secrets in the garden bed
Tomatoes leaning crooked on their stakes
She said the soil remembers what we never said

[Chorus]
Grow through the cracks in the pavement stone
Reach for a sun you have never known
Roots hold tight when the cold wind moans
Nothing that blooms ever grows alone

[Verse 2]
I found her gloves still hanging on the nail"""


def _case(**kwargs):
    return kwargs


CASES = [
    # ------------------------------------------------------------------
    # Suggestions — verse, constrained PERFECT, all three complexities
    # ------------------------------------------------------------------
    _case(id="sugg_verse_perfect_simple", task="suggestions",
          theme="leaving a small town", lyrics=SONG_ROAD,
          target_rhyme_line="Dust is dancing on the dashboard glow",
          rhyme_type="PERFECT", rhyme_scheme="ABAB", current_letter="B",
          section=("VERSE", 2), current_section="VERSE",
          complexity="SIMPLE", use_whole_song_context=False),
    _case(id="sugg_verse_perfect_moderate", task="suggestions",
          theme="leaving a small town", lyrics=SONG_ROAD,
          target_rhyme_line="Dust is dancing on the dashboard glow",
          rhyme_type="PERFECT", rhyme_scheme="ABAB", current_letter="B",
          section=("VERSE", 2), current_section="VERSE",
          complexity="MODERATE", use_whole_song_context=False),
    _case(id="sugg_verse_perfect_complex", task="suggestions",
          theme="leaving a small town", lyrics=SONG_ROAD,
          target_rhyme_line="Dust is dancing on the dashboard glow",
          rhyme_type="PERFECT", rhyme_scheme="ABAB", current_letter="B",
          section=("VERSE", 2), current_section="VERSE",
          complexity="COMPLEX", use_whole_song_context=False),

    # ------------------------------------------------------------------
    # Suggestions — verse, unconstrained (new rhyme sound), 3 complexities
    # ------------------------------------------------------------------
    _case(id="sugg_verse_new_sound_simple", task="suggestions",
          theme="leaving a small town", lyrics=SONG_ROAD,
          target_rhyme_line=None,
          rhyme_type="PERFECT", rhyme_scheme="AABB", current_letter="A",
          section=("VERSE", 2), current_section="VERSE",
          complexity="SIMPLE", use_whole_song_context=False),
    _case(id="sugg_verse_new_sound_moderate", task="suggestions",
          theme="leaving a small town", lyrics=SONG_ROAD,
          target_rhyme_line=None,
          rhyme_type="PERFECT", rhyme_scheme="AABB", current_letter="A",
          section=("VERSE", 2), current_section="VERSE",
          complexity="MODERATE", use_whole_song_context=False),
    _case(id="sugg_verse_new_sound_complex", task="suggestions",
          theme="leaving a small town", lyrics=SONG_ROAD,
          target_rhyme_line=None,
          rhyme_type="PERFECT", rhyme_scheme="AABB", current_letter="A",
          section=("VERSE", 2), current_section="VERSE",
          complexity="COMPLEX", use_whole_song_context=False),

    # ------------------------------------------------------------------
    # Suggestions — bridge, constrained PERFECT, 3 complexities
    # (bridge directive + chorus end-word exclusion)
    # ------------------------------------------------------------------
    _case(id="sugg_bridge_perfect_simple", task="suggestions",
          theme="keeping hope through a hard winter", lyrics=SONG_EMBER,
          target_rhyme_line="All the maps we drew are set in stone",
          rhyme_type="PERFECT", rhyme_scheme="AABB", current_letter="A",
          section=("BRIDGE", 1), current_section="BRIDGE",
          complexity="SIMPLE", use_whole_song_context=False),
    _case(id="sugg_bridge_perfect_moderate", task="suggestions",
          theme="keeping hope through a hard winter", lyrics=SONG_EMBER,
          target_rhyme_line="All the maps we drew are set in stone",
          rhyme_type="PERFECT", rhyme_scheme="AABB", current_letter="A",
          section=("BRIDGE", 1), current_section="BRIDGE",
          complexity="MODERATE", use_whole_song_context=False),
    _case(id="sugg_bridge_perfect_complex", task="suggestions",
          theme="keeping hope through a hard winter", lyrics=SONG_EMBER,
          target_rhyme_line="All the maps we drew are set in stone",
          rhyme_type="PERFECT", rhyme_scheme="AABB", current_letter="A",
          section=("BRIDGE", 1), current_section="BRIDGE",
          complexity="COMPLEX", use_whole_song_context=False),

    # ------------------------------------------------------------------
    # Suggestions — chorus repeat (2nd instance), constrained, 3 complexities
    # (chorus-repeat directive + first-chorus end-word promotion)
    # ------------------------------------------------------------------
    _case(id="sugg_chorus_repeat_simple", task="suggestions",
          theme="electric city nights", lyrics=SONG_CITY,
          target_rhyme_line="We are running on a live wire",
          rhyme_type="PERFECT", rhyme_scheme="AAAA", current_letter="A",
          section=("CHORUS", 2), current_section="CHORUS",
          complexity="SIMPLE", use_whole_song_context=False),
    _case(id="sugg_chorus_repeat_moderate", task="suggestions",
          theme="electric city nights", lyrics=SONG_CITY,
          target_rhyme_line="We are running on a live wire",
          rhyme_type="PERFECT", rhyme_scheme="AAAA", current_letter="A",
          section=("CHORUS", 2), current_section="CHORUS",
          complexity="MODERATE", use_whole_song_context=False),
    _case(id="sugg_chorus_repeat_complex", task="suggestions",
          theme="electric city nights", lyrics=SONG_CITY,
          target_rhyme_line="We are running on a live wire",
          rhyme_type="PERFECT", rhyme_scheme="AAAA", current_letter="A",
          section=("CHORUS", 2), current_section="CHORUS",
          complexity="COMPLEX", use_whole_song_context=False),

    # ------------------------------------------------------------------
    # Suggestions — first chorus instance (no repeat directive)
    # ------------------------------------------------------------------
    _case(id="sugg_chorus_first_perfect", task="suggestions",
          theme="growing where you are planted", lyrics=SONG_GARDEN,
          target_rhyme_line="Grow through the cracks in the pavement stone",
          rhyme_type="PERFECT", rhyme_scheme="AAAA", current_letter="A",
          section=("CHORUS", 1), current_section="CHORUS",
          complexity="MODERATE", use_whole_song_context=False),
    _case(id="sugg_chorus_first_near", task="suggestions",
          theme="growing where you are planted", lyrics=SONG_GARDEN,
          target_rhyme_line="Grow through the cracks in the pavement stone",
          rhyme_type="NEAR", rhyme_scheme="AAAA", current_letter="A",
          section=("CHORUS", 1), current_section="CHORUS",
          complexity="SIMPLE", use_whole_song_context=False),

    # ------------------------------------------------------------------
    # Suggestions — unmarked section (no headers)
    # ------------------------------------------------------------------
    _case(id="sugg_unknown_perfect_moderate", task="suggestions",
          theme="a storm rolling in", lyrics=SONG_PLAIN,
          target_rhyme_line="And every window rattled with the strain",
          rhyme_type="PERFECT", rhyme_scheme="ABCB", current_letter="B",
          section=None, current_section="UNKNOWN",
          complexity="MODERATE", use_whole_song_context=False),
    _case(id="sugg_unknown_perfect_complex", task="suggestions",
          theme="a storm rolling in", lyrics=SONG_PLAIN,
          target_rhyme_line="And every window rattled with the strain",
          rhyme_type="PERFECT", rhyme_scheme="ABCB", current_letter="B",
          section=None, current_section="UNKNOWN",
          complexity="COMPLEX", use_whole_song_context=False),
    _case(id="sugg_unknown_new_sound_simple", task="suggestions",
          theme="a storm rolling in", lyrics=SONG_PLAIN,
          target_rhyme_line=None,
          rhyme_type="PERFECT", rhyme_scheme="AABB", current_letter="A",
          section=None, current_section="UNKNOWN",
          complexity="SIMPLE", use_whole_song_context=False),
    _case(id="sugg_unknown_new_sound_moderate", task="suggestions",
          theme="", lyrics=SONG_PLAIN,
          target_rhyme_line=None,
          rhyme_type="PERFECT", rhyme_scheme="ABAB", current_letter="A",
          section=None, current_section="UNKNOWN",
          complexity="MODERATE", use_whole_song_context=False),

    # ------------------------------------------------------------------
    # Suggestions — whole-song context
    # ------------------------------------------------------------------
    _case(id="sugg_whole_song_constrained", task="suggestions",
          theme="leaving a small town", lyrics=SONG_ROAD,
          target_rhyme_line="Dust is dancing on the dashboard glow",
          rhyme_type="PERFECT", rhyme_scheme="ABAB", current_letter="B",
          section=("VERSE", 2), current_section="VERSE",
          complexity="MODERATE", use_whole_song_context=True),
    _case(id="sugg_whole_song_new_sound", task="suggestions",
          theme="", lyrics=SONG_GARDEN,
          target_rhyme_line=None,
          rhyme_type="PERFECT", rhyme_scheme="AABB", current_letter="A",
          section=("VERSE", 2), current_section="VERSE",
          complexity="MODERATE", use_whole_song_context=True),

    # ------------------------------------------------------------------
    # Suggestions — NEAR and SLANT rhyme types
    # ------------------------------------------------------------------
    _case(id="sugg_verse_near_moderate", task="suggestions",
          theme="leaving a small town", lyrics=SONG_ROAD,
          target_rhyme_line="The engine hummed a promise to the night",
          rhyme_type="NEAR", rhyme_scheme="ABAB", current_letter="A",
          section=("VERSE", 1), current_section="VERSE",
          complexity="MODERATE", use_whole_song_context=False),
    _case(id="sugg_plain_near_simple", task="suggestions",
          theme="a storm rolling in", lyrics=SONG_PLAIN,
          target_rhyme_line="I watched the thunder practice in the rain",
          rhyme_type="NEAR", rhyme_scheme="ABCB", current_letter="B",
          section=None, current_section="UNKNOWN",
          complexity="SIMPLE", use_whole_song_context=False),
    _case(id="sugg_verse_slant_moderate", task="suggestions",
          theme="electric city nights", lyrics=SONG_CITY,
          target_rhyme_line="Strangers trade their shadows in the rain",
          rhyme_type="SLANT", rhyme_scheme="ABAB", current_letter="B",
          section=("VERSE", 2), current_section="VERSE",
          complexity="MODERATE", use_whole_song_context=False),
    _case(id="sugg_bridge_slant_complex", task="suggestions",
          theme="keeping hope through a hard winter", lyrics=SONG_EMBER,
          target_rhyme_line="All the maps we drew are set in stone",
          rhyme_type="SLANT", rhyme_scheme="AABB", current_letter="A",
          section=("BRIDGE", 1), current_section="BRIDGE",
          complexity="COMPLEX", use_whole_song_context=False),

    # ------------------------------------------------------------------
    # Passage rewrite — 3 actions x 2 selections
    # ------------------------------------------------------------------
    _case(id="rw_passage_rephrase_chorus", task="rewrite_passage",
          action="REPHRASE", lyrics=SONG_ROAD,
          selection="Take me down that open road\nWhere the sky forgets my name",
          current_section="CHORUS"),
    _case(id="rw_passage_harder_chorus", task="rewrite_passage",
          action="HARDER_RHYME", lyrics=SONG_ROAD,
          selection="Take me down that open road\nWhere the sky forgets my name",
          current_section="CHORUS"),
    _case(id="rw_passage_punchup_chorus", task="rewrite_passage",
          action="PUNCH_UP", lyrics=SONG_ROAD,
          selection="Take me down that open road\nWhere the sky forgets my name",
          current_section="CHORUS"),
    _case(id="rw_passage_rephrase_verse", task="rewrite_passage",
          action="REPHRASE", lyrics=SONG_EMBER,
          selection="We wore our winter coats around the house",
          current_section="VERSE"),
    _case(id="rw_passage_harder_verse", task="rewrite_passage",
          action="HARDER_RHYME", lyrics=SONG_GARDEN,
          selection="Tomatoes leaning crooked on their stakes\nShe said the soil remembers what we never said",
          current_section="VERSE"),
    _case(id="rw_passage_punchup_verse", task="rewrite_passage",
          action="PUNCH_UP", lyrics=SONG_CITY,
          selection="Concrete rivers running past my door\nNeon puddles shining on the ground",
          current_section="VERSE"),

    # ------------------------------------------------------------------
    # Single-word rewrite — 3 actions x 2 words, plus rejected-retry cases
    # ------------------------------------------------------------------
    _case(id="rw_word_rephrase_glow", task="rewrite_word",
          action="REPHRASE", lyrics=SONG_ROAD, selection="glow",
          selection_word="glow", current_section="VERSE", rejected=[]),
    _case(id="rw_word_harder_glow", task="rewrite_word",
          action="HARDER_RHYME", lyrics=SONG_ROAD, selection="glow",
          selection_word="glow", current_section="VERSE", rejected=[]),
    _case(id="rw_word_punchup_glow", task="rewrite_word",
          action="PUNCH_UP", lyrics=SONG_ROAD, selection="glow",
          selection_word="glow", current_section="VERSE", rejected=[]),
    _case(id="rw_word_rephrase_stone", task="rewrite_word",
          action="REPHRASE", lyrics=SONG_EMBER, selection="stone",
          selection_word="stone", current_section="BRIDGE", rejected=[]),
    _case(id="rw_word_harder_stone", task="rewrite_word",
          action="HARDER_RHYME", lyrics=SONG_EMBER, selection="stone",
          selection_word="stone", current_section="BRIDGE", rejected=[]),
    _case(id="rw_word_punchup_ground", task="rewrite_word",
          action="PUNCH_UP", lyrics=SONG_CITY, selection="ground",
          selection_word="ground", current_section="VERSE", rejected=[]),
    # Retry cases: the app re-prompts with previously returned words rejected.
    _case(id="rw_word_rephrase_glow_retry", task="rewrite_word",
          action="REPHRASE", lyrics=SONG_ROAD, selection="glow",
          selection_word="glow", current_section="VERSE",
          rejected=["gleam", "shine"]),
    _case(id="rw_word_harder_stone_retry", task="rewrite_word",
          action="HARDER_RHYME", lyrics=SONG_EMBER, selection="stone",
          selection_word="stone", current_section="BRIDGE",
          rejected=["alone", "known"]),
    _case(id="rw_word_punchup_rain_retry", task="rewrite_word",
          action="PUNCH_UP", lyrics=SONG_PLAIN, selection="rain",
          selection_word="rain", current_section="UNKNOWN",
          rejected=["storm", "downpour"]),

    # ------------------------------------------------------------------
    # Synonyms
    # ------------------------------------------------------------------
    _case(id="syn_promise", task="synonyms", word="promise",
          line_context="The engine hummed a promise to the night", limit=8),
    _case(id="syn_shining", task="synonyms", word="shining",
          line_context="Neon puddles shining on the ground", limit=8),
    _case(id="syn_crooked", task="synonyms", word="crooked",
          line_context="Tomatoes leaning crooked on their stakes", limit=8),
    _case(id="syn_flickered_no_context", task="synonyms", word="flickered",
          line_context="", limit=8),
]


def selection_start_for(case):
    """Character offset of the selected word for rewrite_word cases (uses the
    last occurrence, matching how these cases position the cursor)."""
    return case["lyrics"].rindex(case["selection_word"])


if __name__ == "__main__":
    from collections import Counter
    counts = Counter(c["task"] for c in CASES)
    ids = [c["id"] for c in CASES]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    print("total cases: %d" % len(CASES))
    for task, n in sorted(counts.items()):
        print("  %-16s %d" % (task, n))
