package com.rhymeai.app.data.model

import kotlinx.serialization.Serializable

@Serializable
data class SongProject(
    val id: String = java.util.UUID.randomUUID().toString(),
    val title: String = "",
    val lyrics: String = "",
    val theme: String = "",
    val updatedAt: Long = System.currentTimeMillis()
)
