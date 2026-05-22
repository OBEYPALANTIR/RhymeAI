package com.rhymeai.app.data.model

import kotlinx.serialization.Serializable

const val TRASH_RETENTION_MILLIS: Long = 30L * 24L * 60L * 60L * 1000L

@Serializable
data class TrashedSongProject(
    val project: SongProject,
    val deletedAt: Long,
    val deleteAfter: Long = deletedAt + TRASH_RETENTION_MILLIS
)
