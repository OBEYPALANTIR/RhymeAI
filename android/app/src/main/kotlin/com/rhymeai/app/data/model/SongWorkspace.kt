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

@Serializable
data class SongWorkspace(
    val selectionStart: Int = 0,
    val selectionEnd: Int = 0,
    val scrollOffset: Float = 0f,
    val alternates: List<LyricAlternate> = emptyList(),
    val versions: List<DraftVersion> = emptyList(),
    val checkpointAt: Long = 0L
) {
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
