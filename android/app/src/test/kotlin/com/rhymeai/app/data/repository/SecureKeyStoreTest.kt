package com.rhymeai.app.data.repository

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class SecureKeyStoreTest {

    private class FakeSecureKeyStore : SecureKeyStore {
        private val store = mutableMapOf<String, String>()
        override fun getKey(provider: String): String = store[provider].orEmpty()
        override fun setKey(provider: String, key: String) { store[provider] = key }
        override fun allKeys(): Map<String, String> =
            SecureKeyStore.SUPPORTED_PROVIDERS.associateWith { store[it].orEmpty() }
        override fun clear() { store.clear() }
    }

    @Test
    fun roundTripsKeyThroughStore() {
        val store: SecureKeyStore = FakeSecureKeyStore()

        store.setKey("GEMINI", "abc")
        store.setKey("OPENAI", "xyz")

        assertEquals("abc", store.getKey("GEMINI"))
        assertEquals("xyz", store.getKey("OPENAI"))
        assertEquals("", store.getKey("CLAUDE"))
        assertEquals(
            mapOf("GEMINI" to "abc", "OPENAI" to "xyz", "CLAUDE" to ""),
            store.allKeys()
        )
    }

    @Test
    fun clearWipesEveryProvider() {
        val store: SecureKeyStore = FakeSecureKeyStore()
        store.setKey("GEMINI", "k")
        store.setKey("OPENAI", "k")
        store.setKey("CLAUDE", "k")

        store.clear()

        assertEquals("", store.getKey("GEMINI"))
        assertEquals("", store.getKey("OPENAI"))
        assertEquals("", store.getKey("CLAUDE"))
    }

    @Test
    fun migrationMovesPopulatedLegacyKeysAndReportsTrue() {
        val store: SecureKeyStore = FakeSecureKeyStore()
        val legacy = mapOf(
            "GEMINI" to "gem-1",
            "OPENAI" to "",
            "CLAUDE" to "cla-1"
        )

        val migrated = ApiKeyMigration.apply(legacy, store)

        assertTrue(migrated)
        assertEquals("gem-1", store.getKey("GEMINI"))
        assertEquals("", store.getKey("OPENAI"))
        assertEquals("cla-1", store.getKey("CLAUDE"))
    }

    @Test
    fun migrationPreservesExistingSecureKeyButStillRequestsLegacyWipe() {
        val store: SecureKeyStore = FakeSecureKeyStore()
        store.setKey("GEMINI", "already-in-secure")

        val hadLegacy = ApiKeyMigration.apply(
            mapOf("GEMINI" to "stale-plaintext", "OPENAI" to "", "CLAUDE" to ""),
            store
        )

        // The stale plaintext must still be wiped by the caller even though
        // nothing was moved — otherwise it survives in DataStore forever.
        assertTrue(hadLegacy)
        assertEquals("already-in-secure", store.getKey("GEMINI"))
    }

    @Test
    fun migrationOnEmptyLegacyDoesNothing() {
        val store: SecureKeyStore = FakeSecureKeyStore()

        val migrated = ApiKeyMigration.apply(
            mapOf("GEMINI" to "", "OPENAI" to "", "CLAUDE" to ""),
            store
        )

        assertFalse(migrated)
        assertEquals("", store.getKey("GEMINI"))
    }

    @Test
    fun migrationPropagatesSecureWriteFailure() {
        val store = object : SecureKeyStore {
            override fun getKey(provider: String): String = ""
            override fun setKey(provider: String, key: String) {
                error("write failed")
            }
            override fun allKeys(): Map<String, String> = emptyMap()
            override fun clear() = Unit
        }

        assertFailsWith<IllegalStateException> {
            ApiKeyMigration.apply(
                mapOf("GEMINI" to "legacy", "OPENAI" to "", "CLAUDE" to ""),
                store
            )
        }
    }
}
