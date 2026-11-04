package com.rhymeai.app.util

/**
 * A memo of results that depend on the pronunciation dictionary. It starts over when the dictionary
 * changes (counts made before it loaded used the spelling fallback), never keeps a result computed
 * against an older dictionary, and holds at most [maxCharacters] of keys, dropping the least
 * recently used. A key longer than [maxKeyCharacters] is computed every time and not kept.
 */
internal class DictionaryMemo<V : Any>(
    private val maxCharacters: Int,
    private val maxKeyCharacters: Int,
    private val generation: () -> Any = { PronunciationDictionary.shared }
) {
    private val entries = LinkedHashMap<String, V>(16, 0.75f, true)
    private var characters = 0
    private var entriesGeneration: Any? = null

    /** Characters of keys currently kept. */
    val retainedCharacters: Int get() = synchronized(this) { characters }

    fun getOrPut(key: String, compute: () -> V): V {
        if (key.length > maxKeyCharacters) return compute()
        while (true) {
            val started = synchronized(this) {
                startGeneration()
                entries[key]?.let { return it }
                entriesGeneration
            }
            // Computed outside the lock; a dictionary that loads meanwhile makes this result stale.
            val computed = compute()
            synchronized(this) {
                if (generation() === started) {
                    startGeneration()
                    entries[key]?.let { return it }
                    entries[key] = computed
                    characters += key.length
                    val eldest = entries.entries.iterator()
                    while (characters > maxCharacters && eldest.hasNext()) {
                        characters -= eldest.next().key.length
                        eldest.remove()
                    }
                    return computed
                }
            }
        }
    }

    private fun startGeneration() {
        val current = generation()
        if (current !== entriesGeneration) {
            entriesGeneration = current
            entries.clear()
            characters = 0
        }
    }
}
