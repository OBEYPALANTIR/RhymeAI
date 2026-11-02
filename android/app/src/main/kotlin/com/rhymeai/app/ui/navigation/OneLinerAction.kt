package com.rhymeai.app.ui.navigation

/** What a widget, Quick Settings tile or link asks the app to do with One Liners. */
enum class OneLinerAction {
    RECORD,
    TYPE,
    OPEN;

    val link: String get() = "$SCHEME://$HOST/${name.lowercase()}"

    companion object {
        const val SCHEME = "writersblock"
        const val HOST = "one-liners"

        /** `writersblock://one-liners/record`, `/type` or `/open`; a bare `writersblock://one-liners` opens the screen. */
        fun parse(link: String?): OneLinerAction? {
            val uri = runCatching { java.net.URI(link ?: return null) }.getOrNull() ?: return null
            if (!uri.scheme.equals(SCHEME, ignoreCase = true) || !uri.host.equals(HOST, ignoreCase = true)) return null
            val route = uri.path.orEmpty().trim('/').substringBefore('/').lowercase().ifEmpty { "open" }
            return entries.firstOrNull { it.name.lowercase() == route }
        }
    }
}
