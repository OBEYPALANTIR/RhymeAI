package com.rhymeai.app.data.repository

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Provider-keyed credential store. The real implementation persists encrypted at rest
 * using Android Keystore via EncryptedSharedPreferences; the interface exists so that
 * migration and consumer logic can be unit-tested with an in-memory fake.
 */
interface SecureKeyStore {
    fun getKey(provider: String): String
    fun setKey(provider: String, key: String)
    fun allKeys(): Map<String, String>
    fun clear()

    companion object {
        val SUPPORTED_PROVIDERS: List<String> = listOf("GEMINI", "OPENAI", "CLAUDE")
    }
}

class EncryptedPrefsKeyStore(context: Context) : SecureKeyStore {
    private val prefs by lazy {
        val masterKey = MasterKey.Builder(context.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context.applicationContext,
            FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    override fun getKey(provider: String): String =
        prefs.getString(provider, "").orEmpty()

    override fun setKey(provider: String, key: String) {
        check(prefs.edit().putString(provider, key).commit()) {
            "Secure credential storage failed"
        }
    }

    override fun allKeys(): Map<String, String> =
        SecureKeyStore.SUPPORTED_PROVIDERS.associateWith { getKey(it) }

    override fun clear() {
        prefs.edit().clear().apply()
    }

    companion object {
        private const val FILE_NAME = "rhymeai_secure_keys"
    }
}

/**
 * One-shot migration of plaintext API keys into the secure store. Pure function so it
 * can be unit-tested without Android dependencies. Returns true iff any legacy
 * plaintext entry exists, so the caller knows to wipe the legacy storage — even when
 * the secure store already held the key (e.g. a crash between migrate and wipe on a
 * previous launch); otherwise the plaintext copy would survive forever.
 */
object ApiKeyMigration {
    fun apply(legacyPlaintext: Map<String, String>, secure: SecureKeyStore): Boolean {
        var hadLegacy = false
        for (provider in SecureKeyStore.SUPPORTED_PROVIDERS) {
            val candidate = legacyPlaintext[provider]
            if (candidate.isNullOrEmpty()) continue
            hadLegacy = true
            if (secure.getKey(provider).isEmpty()) {
                secure.setKey(provider, candidate)
            }
        }
        return hadLegacy
    }
}
