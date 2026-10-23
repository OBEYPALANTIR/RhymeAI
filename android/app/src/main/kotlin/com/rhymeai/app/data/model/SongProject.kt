package com.rhymeai.app.data.model

import kotlinx.serialization.Serializable

@Serializable
data class SongProject(
    val id: String = java.util.UUID.randomUUID().toString(),
    val title: String = "",
    val lyrics: String = "",
    val theme: String = "",
    val updatedAt: Long = System.currentTimeMillis(),
    /** A37: [updatedAt] is a first-seen repair of a missing time (A32), not an edit. */
    val precedenceRepaired: Boolean = false
)
