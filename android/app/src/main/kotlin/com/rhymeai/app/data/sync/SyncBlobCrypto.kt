package com.rhymeai.app.data.sync

import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Passphrase-derived AES-GCM envelopes shared with iOS.
 *
 * Recording payloads retain RAI1. Project manifests are written as v3 under
 * RAI3; v2 under RAI2 and v1 under RAI1 remain readable. The actual header bytes
 * (magic, salt and IV) are authenticated as AAD.
 */
object SyncBlobCrypto {
    private val RECORDING_MAGIC = "RAI1".toByteArray(Charsets.US_ASCII)
    private val LEGACY_MANIFEST_MAGIC = "RAI2".toByteArray(Charsets.US_ASCII)
    private val MANIFEST_MAGIC = "RAI3".toByteArray(Charsets.US_ASCII)
    private const val SALT_BYTES = 16
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128
    private const val KEY_BITS = 256
    internal const val ENVELOPE_OVERHEAD_BYTES = 4 + SALT_BYTES + IV_BYTES + (TAG_BITS / 8)

    // OWASP 2023 floor for PBKDF2-HmacSHA256. Derivation runs once per
    // sync push/pull, so the ~0.5s cost on a phone is acceptable.
    private const val PBKDF2_ITERATIONS = 210_000

    private val random = SecureRandom()

    internal fun envelopeSizeForPlaintext(plaintextBytes: Long): Long {
        require(plaintextBytes >= 0) { "Plaintext size must be non-negative" }
        return Math.addExact(plaintextBytes, ENVELOPE_OVERHEAD_BYTES.toLong())
    }

    /** Recording payloads must remain byte-compatible with the existing RAI1 format. */
    fun seal(plaintext: ByteArray, passphrase: CharArray): ByteArray =
        sealWithMagic(plaintext, passphrase, randomSalt(), randomIv(), RECORDING_MAGIC)

    internal fun seal(
        plaintext: ByteArray,
        passphrase: CharArray,
        salt: ByteArray,
        iv: ByteArray
    ): ByteArray = sealWithMagic(plaintext, passphrase, salt, iv, RECORDING_MAGIC)

    fun sealManifest(plaintext: ByteArray, passphrase: CharArray): ByteArray =
        sealWithMagic(plaintext, passphrase, randomSalt(), randomIv(), MANIFEST_MAGIC)

    internal fun sealManifest(
        plaintext: ByteArray,
        passphrase: CharArray,
        salt: ByteArray,
        iv: ByteArray
    ): ByteArray = sealWithMagic(plaintext, passphrase, salt, iv, MANIFEST_MAGIC)

    private fun randomSalt() = ByteArray(SALT_BYTES).also(random::nextBytes)
    private fun randomIv() = ByteArray(IV_BYTES).also(random::nextBytes)

    private fun sealWithMagic(
        plaintext: ByteArray,
        passphrase: CharArray,
        salt: ByteArray,
        iv: ByteArray,
        magic: ByteArray
    ): ByteArray {
        requirePortablePassphrase(passphrase)
        require(salt.size == SALT_BYTES) { "Salt must be $SALT_BYTES bytes" }
        require(iv.size == IV_BYTES) { "IV must be $IV_BYTES bytes" }
        val header = magic + salt + iv
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, deriveKey(passphrase, salt), GCMParameterSpec(TAG_BITS, iv))
        cipher.updateAAD(header)
        return header + cipher.doFinal(plaintext)
    }

    data class OpenedManifest(val plaintext: ByteArray, val version: Int)

    fun openManifest(envelope: ByteArray, passphrase: CharArray): OpenedManifest {
        if (envelope.size < RECORDING_MAGIC.size) throw SyncBlobFormatException("Envelope is truncated")
        val magic = envelope.copyOfRange(0, RECORDING_MAGIC.size)
        val version = when {
            magic.contentEquals(RECORDING_MAGIC) -> 1
            magic.contentEquals(LEGACY_MANIFEST_MAGIC) -> 2
            magic.contentEquals(MANIFEST_MAGIC) -> 3
            magic[0] == 'R'.code.toByte() &&
                magic[1] == 'A'.code.toByte() &&
                magic[2] == 'I'.code.toByte() ->
                throw SyncBlobFormatException("Unsupported envelope version")
            else -> throw SyncBlobFormatException("Unrecognized envelope format")
        }
        return OpenedManifest(openWithMagic(envelope, passphrase, magic), version)
    }

    /** Recording files deliberately accept only the original RAI1 envelope. */
    fun open(envelope: ByteArray, passphrase: CharArray): ByteArray =
        openWithMagic(envelope, passphrase, RECORDING_MAGIC)

    private fun openWithMagic(
        envelope: ByteArray,
        passphrase: CharArray,
        magic: ByteArray
    ): ByteArray {
        if (!isPortablePassphrase(passphrase)) {
            throw SyncBlobSealException("Passphrase uses unsupported characters for cross-platform Drive sync")
        }
        val headerLength = magic.size + SALT_BYTES + IV_BYTES
        if (envelope.size < headerLength + TAG_BITS / 8) {
            throw SyncBlobFormatException("Envelope is truncated (${envelope.size} bytes)")
        }
        if (!envelope.copyOfRange(0, magic.size).contentEquals(magic)) {
            throw SyncBlobFormatException("Unrecognized envelope format")
        }
        val salt = envelope.copyOfRange(magic.size, magic.size + SALT_BYTES)
        val iv = envelope.copyOfRange(magic.size + SALT_BYTES, headerLength)
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

    private fun requirePortablePassphrase(passphrase: CharArray) {
        require(isPortablePassphrase(passphrase)) {
            "Drive sync passphrase must use printable ASCII so Android and iOS derive the same key"
        }
    }

    private fun isPortablePassphrase(passphrase: CharArray): Boolean =
        passphrase.isNotEmpty() && passphrase.all { it.code in 0x20..0x7E }
}

open class SyncBlobSealException(message: String, cause: Throwable? = null) : Exception(message, cause)
class SyncBlobFormatException(message: String) : SyncBlobSealException(message)
