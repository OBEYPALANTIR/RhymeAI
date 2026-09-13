package com.rhymeai.app.data.model

import kotlinx.serialization.Serializable

@Serializable
data class SavedLocalModel(
    val id: String,
    val displayName: String,
    val fileName: String,
    val isCustom: Boolean,
    val verifiedCatalogSha256: String? = null,
    val verifiedSizeBytes: Long? = null,
    val verifiedLastModifiedMillis: Long? = null
)
