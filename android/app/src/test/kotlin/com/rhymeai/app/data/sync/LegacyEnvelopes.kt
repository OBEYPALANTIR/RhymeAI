package com.rhymeai.app.data.sync

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Test-only writer of the pre-v4 RAI envelopes. The app only reads them now; tests
 * build legacy backups with this and check it byte for byte against the vectors.
 */
object LegacyEnvelopes {
    private val random = SecureRandom()

    fun seal(plaintext: ByteArray, passphrase: CharArray, salt: ByteArray = randomBytes(16), iv: ByteArray = randomBytes(12)) =
        sealWithMagic("RAI1", plaintext, passphrase, salt, iv)

    fun sealManifest(plaintext: ByteArray, passphrase: CharArray, salt: ByteArray = randomBytes(16), iv: ByteArray = randomBytes(12)) =
        sealWithMagic("RAI3", plaintext, passphrase, salt, iv)

    private fun randomBytes(size: Int) = ByteArray(size).also(random::nextBytes)

    private fun sealWithMagic(magic: String, plaintext: ByteArray, passphrase: CharArray, salt: ByteArray, iv: ByteArray): ByteArray {
        require(passphrase.isNotEmpty() && passphrase.all { it.code in 0x20..0x7E }) { "Passphrase must be printable ASCII" }
        val header = magic.toByteArray(Charsets.US_ASCII) + salt + iv
        val spec = PBEKeySpec(passphrase, salt, 210_000, 256)
        val key = SecretKeySpec(SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded, "AES")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        cipher.updateAAD(header)
        return header + cipher.doFinal(plaintext)
    }
}
