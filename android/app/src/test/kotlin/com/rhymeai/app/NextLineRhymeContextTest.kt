package com.rhymeai.app

import com.rhymeai.app.ui.components.rhymeSchemeRows
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * One table for both platforms. The iOS copy is `NextLineRhymeContextTests.swift`;
 * keep the rows identical. `|` marks the cursor. `after` is the text once the
 * suggestion "NEW" is accepted, with `|` where the cursor lands.
 */
internal data class NextLineCase(
    val id: String,
    val scheme: String,
    val lyrics: String,
    val letter: String,
    val anchor: String?,
    val after: String
) {
    val text: String get() = lyrics.replace("|", "")
    val cursor: Int get() = lyrics.indexOf('|')
    val textAfter: String get() = after.replace("|", "")
    val cursorAfter: Int get() = after.indexOf('|')
}

internal val nextLineCases = listOf(
    // AABB
    NextLineCase("aabb-end-of-line-1", "AABB", "first light|", "A", "first light", "first light\nNEW\n|"),
    NextLineCase("aabb-end-of-line-2", "AABB", "first light\nsecond night|", "B", null, "first light\nsecond night\nNEW\n|"),
    NextLineCase("aabb-end-of-line-3", "AABB", "one\ntwo\nthree|", "B", "three", "one\ntwo\nthree\nNEW\n|"),
    NextLineCase("aabb-start-of-line-2", "AABB", "one\n|two", "B", null, "one\ntwo\nNEW\n|"),
    // ABAB, including the three reported defects
    NextLineCase("abab-end-of-line-2", "ABAB", "first glow\nsecond rain|", "A", "first glow", "first glow\nsecond rain\nNEW\n|"),
    NextLineCase("abab-empty-line-3", "ABAB", "first glow\nsecond rain\n|", "A", "first glow", "first glow\nsecond rain\nNEW\n|"),
    NextLineCase("abab-mid-line-3-of-4", "ABAB", "first glow\nsecond rain\nthi|rd road\nfourth rain", "B", "second rain", "first glow\nsecond rain\nthird road\nNEW|\nfourth rain"),
    NextLineCase("abab-end-of-line-3", "ABAB", "first glow\nsecond rain\nthird road|", "B", "second rain", "first glow\nsecond rain\nthird road\nNEW\n|"),
    NextLineCase("abab-end-of-line-1", "ABAB", "first glow|", "B", null, "first glow\nNEW\n|"),
    // ABCB
    NextLineCase("abcb-end-of-line-2", "ABCB", "one\ntwo|", "C", null, "one\ntwo\nNEW\n|"),
    NextLineCase("abcb-end-of-line-3", "ABCB", "one\ntwo\nthree|", "B", "two", "one\ntwo\nthree\nNEW\n|"),
    // Custom schemes
    NextLineCase("abba-end-of-line-2", "ABBA", "one\ntwo|", "B", "two", "one\ntwo\nNEW\n|"),
    NextLineCase("abba-end-of-line-3", "ABBA", "one\ntwo\nthree|", "A", "one", "one\ntwo\nthree\nNEW\n|"),
    NextLineCase("aabccb-empty-line-6", "AABCCB", "one\ntwo\nthree\nfour\nfive\n|", "B", "three", "one\ntwo\nthree\nfour\nfive\nNEW\n|"),
    // First line of a song
    NextLineCase("first-line-empty-song", "BABA", "|", "B", null, "NEW\n|"),
    NextLineCase("first-line-under-header", "ABAB", "[Verse 1]\n|", "A", null, "[Verse 1]\nNEW\n|"),
    NextLineCase("first-line-cursor-on-header", "ABAB", "[Ver|se 1]", "A", null, "[Verse 1]\nNEW\n|"),
    // Second stanza: after a blank line, after a header
    NextLineCase("stanza-2-first-line-after-blank", "ABAB", "one\ntwo\n\n|", "A", null, "one\ntwo\n\nNEW\n|"),
    NextLineCase("stanza-2-second-line-after-blank", "AABB", "one\ntwo\n\nthree|", "A", "three", "one\ntwo\n\nthree\nNEW\n|"),
    NextLineCase("stanza-2-new-sound-after-blank", "ABAB", "one\ntwo\n\nthree|", "B", null, "one\ntwo\n\nthree\nNEW\n|"),
    NextLineCase("stanza-2-first-line-after-header", "ABAB", "one\ntwo\n[Chorus]\n|", "A", null, "one\ntwo\n[Chorus]\nNEW\n|"),
    NextLineCase("stanza-2-third-line-after-header", "ABAB", "one\ntwo\n[Chorus]\nthree\nfour|", "A", "three", "one\ntwo\n[Chorus]\nthree\nfour\nNEW\n|"),
    NextLineCase("stanza-2-after-blank-and-header", "AABB", "one\ntwo\n\n[Chorus]\nthree|", "A", "three", "one\ntwo\n\n[Chorus]\nthree\nNEW\n|"),
    NextLineCase("stanza-1-line-before-later-stanza", "ABAB", "one\ntwo|\n\nthree", "A", "one", "one\ntwo\nNEW|\n\nthree"),
    NextLineCase("separator-line-continues-stanza-1", "ABAB", "one\ntwo\n|\nthree", "A", "one", "one\ntwo\nNEW\n|\nthree"),
    NextLineCase("whitespace-only-cursor-line", "ABAB", "one\ntwo\n  |", "A", "one", "one\ntwo\nNEW\n|"),
    NextLineCase("whitespace-only-separator", "AABB", "one\ntwo\n \nthree|", "A", "three", "one\ntwo\n \nthree\nNEW\n|"),
    // Stanza longer than the scheme: the scheme repeats
    NextLineCase("aabb-line-5-wraps", "AABB", "one\ntwo\nthree\nfour|", "A", "two", "one\ntwo\nthree\nfour\nNEW\n|"),
    NextLineCase("aabb-line-6-wraps", "AABB", "one\ntwo\nthree\nfour\nfive\n|", "A", "five", "one\ntwo\nthree\nfour\nfive\nNEW\n|"),
    // Emoji before the cursor (UTF-16 offsets)
    NextLineCase("emoji-end-of-line-2", "AABB", "🔥🔥 first light\nsecond night|", "B", null, "🔥🔥 first light\nsecond night\nNEW\n|"),
    NextLineCase("emoji-empty-line-3", "ABAB", "🔥🔥 first glow\n🎵 second rain\n|", "A", "🔥🔥 first glow", "🔥🔥 first glow\n🎵 second rain\nNEW\n|"),
    NextLineCase("emoji-mid-line-1", "AABB", "🔥🔥 fi|rst light\nsecond night", "A", "🔥🔥 first light", "🔥🔥 first light\nNEW|\nsecond night"),
    // Every earlier row with the new line's letter, back to the stanza start, ends at the anchor.
)

class NextLineRhymeContextTest {
    @Test
    fun letterAndAnchorDescribeTheLineThatWillBeInserted() {
        for (case in nextLineCases) {
            val context = RhymeContextAnalyzer.compute(case.text, case.cursor, case.scheme)

            assertEquals(case.letter, context.currentLetter, "${case.id} letter")
            assertEquals(case.anchor, context.targetLine, "${case.id} anchor")
        }
    }

    @Test
    fun schemePreviewMarksTheNewLineWithTheLetterSentToTheModel() {
        for (case in nextLineCases.filter { it.text.isNotEmpty() }) {
            val context = RhymeContextAnalyzer.compute(case.text, case.cursor, case.scheme)
            val rows = rhymeSchemeRows(context, case.scheme)
            val current = rows.filter { it.isCurrent }

            assertEquals(1, current.size, "${case.id} one current row")
            assertEquals(case.letter, current.first().letter, "${case.id} preview letter")
            assertEquals("", current.first().line.trim(), "${case.id} preview row is the new line")

            // Every earlier row with the new line's letter, back to the stanza start, ends at the anchor.
            val currentIndex = rows.indexOfFirst { it.isCurrent }
            val stanzaStart = rows.take(currentIndex).indexOfLast { it.letter == null } + 1
            val previewAnchor = rows.subList(stanzaStart, currentIndex).lastOrNull { it.letter == case.letter }?.line
            assertEquals(case.anchor, previewAnchor, "${case.id} preview anchor")
        }
    }
}
