package com.rhymeai.app.data.model

enum class ExportFormat(
    val label: String,
    val description: String,
    val mimeType: String,
    val extension: String
) {
    TXT(
        label = "Plain Text",
        description = "Lyrics only. Universal.",
        mimeType = "text/plain",
        extension = "txt"
    ),
    JSON(
        label = "Project JSON",
        description = "Title, lyrics, theme. Re-importable.",
        mimeType = "application/json",
        extension = "json"
    ),
    PDF(
        label = "Lyric Sheet (PDF)",
        description = "Print-ready formatted sheet.",
        mimeType = "application/pdf",
        extension = "pdf"
    ),
    LRC(
        label = "Timed Lyrics (.lrc)",
        description = "DAW/player format. Empty timestamps for now.",
        mimeType = "application/octet-stream",
        extension = "lrc"
    )
}
