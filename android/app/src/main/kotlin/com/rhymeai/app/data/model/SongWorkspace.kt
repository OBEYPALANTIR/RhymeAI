package com.rhymeai.app.data.model

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class LyricAlternate(val id: String = UUID.randomUUID().toString(), val text: String, val createdAt: Long)

@Serializable
data class DraftVersion(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val lyrics: String,
    val theme: String,
    val createdAt: Long
)

/**
 * One turn of the generative assistant conversation. User turns hold the message shown in the
 * thread (plus optional action/form context sent to the model); assistant turns hold the raw
 * OpenUI Lang program, re-parsed and re-rendered when the thread is shown.
 */
@Serializable
data class AssistantTurn(
    val id: String = UUID.randomUUID().toString(),
    val role: String,
    val text: String,
    val context: String? = null,
    val createdAt: Long
) {
    companion object {
        const val USER = "user"
        const val ASSISTANT = "assistant"
    }
}

@Serializable
data class SongWorkspace(
    val selectionStart: Int = 0,
    val selectionEnd: Int = 0,
    val scrollOffset: Float = 0f,
    val alternates: List<LyricAlternate> = emptyList(),
    val versions: List<DraftVersion> = emptyList(),
    val checkpointAt: Long = 0L,
    val assistantTurns: List<AssistantTurn> = emptyList()
) {
    fun appendAssistantTurn(turn: AssistantTurn): SongWorkspace =
        copy(assistantTurns = (assistantTurns + turn).takeLast(MAX_ASSISTANT_TURNS))

    companion object {
        /** Keeps the stored notebook small; older turns drop off the front. */
        const val MAX_ASSISTANT_TURNS = 40
    }

    fun keep(text: String, now: Long): SongWorkspace {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || alternates.any { it.text == trimmed }) return this
        return copy(alternates = (listOf(LyricAlternate(text = trimmed, createdAt = now)) + alternates).take(50))
    }

    fun checkpoint(title: String, lyrics: String, theme: String, now: Long, force: Boolean): SongWorkspace {
        if (lyrics.isBlank() && title.isBlank() && theme.isBlank()) return this
        if (!force && now - checkpointAt < 5 * 60 * 1000L) return this
        val existing = versions.firstOrNull { it.lyrics == lyrics && it.title == title && it.theme == theme }
        val version = existing ?: DraftVersion(title = title, lyrics = lyrics, theme = theme, createdAt = now)
        return copy(versions = (listOf(version) + versions.filter { it.id != version.id }).take(20), checkpointAt = now)
    }
}
