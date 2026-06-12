package com.rhymeai.app.data.sync

import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Sealed-envelope encryption for the Drive sync blob.
 *
 * The blob must be readable on a user's *other* devices, so the key cannot
 * live in the Android Keystore (keys don't travel) — it is derived from a
 * user passphrase instead. AES-GCM provides confidentiality and integrity in
 * one primitive: the GCM tag is the tamper check, and the header (magic,
 * salt, IV) is bound as AAD so it can't be swapped either. A tampered or
 * wrong-passphrase envelope fails closed with [SyncBlobSealException].
 *
 * Envelope layout: magic "RAI1" (4) | salt (16) | IV (12) | ciphertext+tag.
 *
 * Pure JVM (javax.crypto only) so it is unit-testable without a device. The
 * Drive client that will produce/consume these envelopes does not exist yet;
 * iOS needs no counterpart because its sync rides CloudKit's own encryption.
 */
object SyncBlobCrypto {

    /** Bumping the magic is the envelope's schema version. */
    private val MAGIC = "RAI1".toByteArray(Charsets.US_ASCII)
    private const val SALT_BYTES = 16
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128
    private const val KEY_BITS = 256

    // OWASP 2023 floor for PBKDF2-HmacSHA256. Derivation runs once per
    // sync push/pull, so the ~0.5s cost on a phone is acceptable.
    private const val PBKDF2_ITERATIONS = 210_000

    private val random = SecureRandom()

    fun seal(plaintext: ByteArray, passphrase: CharArray): ByteArray {
        require(passphrase.isNotEmpty()) { "Passphrase must not be empty" }
        val salt = ByteArray(SALT_BYTES).also(random::nextBytes)
        val iv = ByteArray(IV_BYTES).also(random::nextBytes)
        val header = MAGIC + salt + iv

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, deriveKey(passphrase, salt), GCMParameterSpec(TAG_BITS, iv))
        cipher.updateAAD(header)
        return header + cipher.doFinal(plaintext)
    }

    fun open(envelope: ByteArray, passphrase: CharArray): ByteArray {
        require(passphrase.isNotEmpty()) { "Passphrase must not be empty" }
        val headerLength = MAGIC.size + SALT_BYTES + IV_BYTES
        if (envelope.size <= headerLength) {
            throw SyncBlobSealException("Envelope is truncated (${envelope.size} bytes)")
        }
        val magic = envelope.copyOfRange(0, MAGIC.size)
        if (!magic.contentEquals(MAGIC)) {
            throw SyncBlobSealException("Unrecognized envelope format — refusing to interpret")
        }
        val salt = envelope.copyOfRange(MAGIC.size, MAGIC.size + SALT_BYTES)
        val iv = envelope.copyOfRange(MAGIC.size + SALT_BYTES, headerLength)
        val header = envelope.copyOfRange(0, headerLength)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, deriveKey(passphrase, salt), GCMParameterSpec(TAG_BITS, iv))
        cipher.updateAAD(header)
        return try {
            cipher.doFinal(envelope, headerLength, envelope.size - headerLength)
        } catch (e: AEADBadTagException) {
            throw SyncBlobSealException("Envelope failed authentication — wrong passphrase or tampered data", e)
        }
    }

    private fun deriveKey(passphrase: CharArray, salt: ByteArray): SecretKeySpec {
        val spec = PBEKeySpec(passphrase, salt, PBKDF2_ITERATIONS, KEY_BITS)
        val key = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec)
        spec.clearPassword()
        return SecretKeySpec(key.encoded, "AES")
    }
}

class SyncBlobSealException(message: String, cause: Throwable? = null) : Exception(message, cause)
