package com.rhymeai.app.data.model

import com.rhymeai.app.util.ProsodyAnalyzer
import com.rhymeai.app.util.RhymeConstraint
import com.rhymeai.app.util.RhymePhonetics
import kotlinx.serialization.Serializable

/** A stray lyric line kept apart from any song until the writer sends it to one. */
@Serializable
data class OneLiner(
    val id: String = java.util.UUID.randomUUID().toString(),
    val text: String = "",
    val createdAt: Long = System.currentTimeMillis(),
    /** File name under the one-liners audio folder; null for a typed line. */
    val audioFileName: String? = null,
    val audioDurationMs: Long = 0L,
    /** The song the line was sent to. A plain id, so deleting the song never touches the line. */
    val usedInProjectId: String? = null,
    // Prosody cache, recomputed whenever the text is saved (see withText).
    val syllableCount: Int = 0,
    /** End-word rhyme keys, joined by `|`. */
    val rhymeKeys: String = "",
    /** One digit per syllable: 0 unstressed, 1 primary, 2 secondary. */
    val stressPattern: String = ""
) {
    /** The line with new (trimmed) words and the prosody cache that follows them. */
    fun withText(newText: String): OneLiner {
        val words = newText.trim()
        val prosody = ProsodyAnalyzer.analyzeLine(words)
        return copy(
            text = words,
            syllableCount = prosody.syllableCount,
            stressPattern = prosody.stressPattern.joinToString(""),
            rhymeKeys = RhymePhonetics.rhymeKeys(RhymeConstraint.lineEndWord(words)).joinToString("|")
        )
    }

    /** "10 syl · bathroom": the syllable count and the end word the line rhymes on. */
    val prosodyBadge: String
        get() = RhymeConstraint.lineEndWord(text).let { end ->
            if (end.isEmpty()) "$syllableCount syl" else "$syllableCount syl · $end"
        }
}

@Serializable
data class TrashedOneLiner(
    val line: OneLiner,
    val deletedAt: Long,
    val deleteAfter: Long = deletedAt + TRASH_RETENTION_MILLIS
)

/** What the home screen widget shows: written by the store after every change. */
@Serializable
data class OneLinersSnapshot(
    val count: Int,
    val lines: List<Line>,
    val appearance: String
) {
    @Serializable
    data class Line(val id: String, val text: String, val createdAt: Long, val hasAudio: Boolean)

    companion object {
        const val LINE_LIMIT = 3
    }
}
