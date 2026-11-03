package com.rhymeai.app

import com.rhymeai.app.data.model.SongProject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ContinueSongTest {
    private val opened = SongProject(id = "opened", title = "Opened", updatedAt = 1_000L)
    private val touched = SongProject(id = "touched", title = "Touched", updatedAt = 9_000L)

    @Test
    fun `continue offers the song last open in the editor even when another was updated later`() {
        // A one liner sent to "touched" from the Welcome screen bumps its time; Continue stays put.
        assertEquals(opened, continueSong(listOf(opened, touched), lastOpenedId = "opened"))
    }

    @Test
    fun `continue falls back to the most recently updated song`() {
        assertEquals(touched, continueSong(listOf(opened, touched), lastOpenedId = null))
        // The last-opened song was deleted (or never saved).
        assertEquals(touched, continueSong(listOf(opened, touched), lastOpenedId = "gone"))
    }

    @Test
    fun `continue offers nothing without songs`() {
        assertNull(continueSong(emptyList(), lastOpenedId = "opened"))
    }
}
