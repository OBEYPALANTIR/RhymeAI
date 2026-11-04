package com.rhymeai.app.util

/**
 * A memo of results that depend on the pronunciation dictionary. It starts over when the dictionary
 * changes (counts made before it loaded used the spelling fallback), never keeps a result computed
 * against another dictionary than the current one, and holds at most [maxCharacters] of keys,
 * dropping the least recently used. A key longer than [maxKeyCharacters] is kept only as the latest
 * version for its slot (a lyric line's index), so an unchanged long line is reused without its
 * edit history piling up.
 */
internal class DictionaryMemo<G : Any, V : Any>(
    private val maxCharacters: Int,
    private val maxKeyCharacters: Int,
    private val generation: () -> G
) {
    private class Latest<V>(val key: String, val value: V)

    private val entries = LinkedHashMap<String, V>(16, 0.75f, true)
    private val latestBySlot = object : LinkedHashMap<Int, Latest<V>>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, Latest<V>>) = size > MAX_SLOTS
    }
    private var characters = 0
    private var entriesGeneration: G? = null

    /** Characters of keys currently kept in the bounded part of the memo. */
    val retainedCharacters: Int get() = synchronized(this) { characters }

    /** The result for [key], computed against the dictionary it is handed when not already kept. */
    fun getOrPut(key: String, slot: Int = -1, compute: (G) -> V): V {
        val oversized = key.length > maxKeyCharacters
        if (oversized && slot < 0) return compute(generation())
        while (true) {
            val started = generation() // read once: computed against, and compared when storing
            synchronized(this) {
                adopt(started)
                if (oversized) {
                    latestBySlot[slot]?.takeIf { it.key == key }?.let { return it.value }
                } else {
                    entries[key]?.let { return it }
                }
            }
            val computed = compute(started)
            synchronized(this) {
                // A dictionary that loaded while this ran makes the result stale: drop it and rerun.
                if (generation() === started && entriesGeneration === started) {
                    if (oversized) {
                        latestBySlot[slot] = Latest(key, computed)
                    } else {
                        entries[key]?.let { return it }
                        entries[key] = computed
                        characters += key.length
                        val eldest = entries.entries.iterator()
                        while (characters > maxCharacters && eldest.hasNext()) {
                            characters -= eldest.next().key.length
                            eldest.remove()
                        }
                    }
                    return computed
                }
            }
        }
    }

    private fun adopt(current: G) {
        if (current !== entriesGeneration) {
            entriesGeneration = current
            entries.clear()
            latestBySlot.clear()
            characters = 0
        }
    }

    private companion object {
        const val MAX_SLOTS = 64
    }
}

/** A [DictionaryMemo] over the shared pronunciation dictionary. */
internal fun <V : Any> pronunciationMemo(maxCharacters: Int, maxKeyCharacters: Int) =
    DictionaryMemo<PronunciationDictionary, V>(maxCharacters, maxKeyCharacters) { PronunciationDictionary.shared }
