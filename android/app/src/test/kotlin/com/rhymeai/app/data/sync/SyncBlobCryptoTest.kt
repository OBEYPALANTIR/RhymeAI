package com.rhymeai.app.data.sync

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import java.util.Base64
import org.junit.Test

class SyncBlobCryptoTest {

    private val payload = """{"version":1,"projects":[{"title":"Midnight Notes"}]}""".toByteArray()
    private val passphrase = "correct horse battery staple".toCharArray()
    private val goldenPlaintext = """{"version":1,"projects":[],"trashed":[],"recordings":[],"savedAt":1700000000000,"savedByClientId":"android-fixture"}""".toByteArray()
    private val goldenEnvelopeBase64 = "UkFJMQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhtizcOcwuED9qmh1u+pIuacjCXfzEdC4XqsUgnAZ08InG+/2sOGiVfCbTNTgVs/qDX5tg+Xq/8BEH3xh/kmBcKKyayJPnin4qkQQO5xj50WFhaXKsgIOrAWlBrJcXMfe1Y6EmdzpzG87TFCQgajLtF4GAU5Pgh+VRicHt164bxqXJ5xxeE="

    @Test
    fun sealedEnvelopeRoundTripsWithSamePassphrase() {
        val envelope = SyncBlobCrypto.seal(payload, passphrase)
        assertArrayEquals(payload, SyncBlobCrypto.open(envelope, passphrase))
    }

    @Test
    fun opensSharedRAI1GoldenFixture() {
        val envelope = Base64.getDecoder().decode(goldenEnvelopeBase64)
        assertArrayEquals(goldenPlaintext, SyncBlobCrypto.open(envelope, passphrase))
    }

    @Test
    fun deterministicSealMatchesSharedRAI1GoldenFixture() {
        val salt = ByteArray(16) { it.toByte() }
        val iv = ByteArray(12) { (0x10 + it).toByte() }

        val envelope = SyncBlobCrypto.seal(goldenPlaintext, passphrase, salt, iv)

        assertArrayEquals(Base64.getDecoder().decode(goldenEnvelopeBase64), envelope)
    }


    @Test
    fun nonAsciiPassphraseFailsBeforeDerivation() {
        assertThrows(IllegalArgumentException::class.java) {
            SyncBlobCrypto.seal(payload, "café".toCharArray())
        }
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(Base64.getDecoder().decode(goldenEnvelopeBase64), "café".toCharArray())
        }
    }
    @Test
    fun wrongPassphraseFailsClosed() {
        val envelope = SyncBlobCrypto.seal(payload, passphrase)
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(envelope, "not the passphrase".toCharArray())
        }
    }

    @Test
    fun tamperedCiphertextFailsAuthentication() {
        val envelope = SyncBlobCrypto.seal(payload, passphrase)
        envelope[envelope.size - 1] = (envelope.last().toInt() xor 0x01).toByte()
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(envelope, passphrase)
        }
    }

    @Test
    fun tamperedHeaderSaltFailsAuthentication() {
        val envelope = SyncBlobCrypto.seal(payload, passphrase)
        envelope[6] = (envelope[6].toInt() xor 0x01).toByte() // inside the salt
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(envelope, passphrase)
        }
    }

    @Test
    fun unrecognizedMagicIsRejectedBeforeDecryption() {
        val envelope = SyncBlobCrypto.seal(payload, passphrase)
        envelope[0] = 'X'.code.toByte()
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(envelope, passphrase)
        }
    }

    @Test
    fun truncatedEnvelopeIsRejected() {
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(ByteArray(8), passphrase)
        }
    }

    @Test
    fun eachSealUsesFreshSaltAndIv() {
        val first = SyncBlobCrypto.seal(payload, passphrase)
        val second = SyncBlobCrypto.seal(payload, passphrase)
        assertFalse(first.contentEquals(second))
        // salt+IV live in bytes 4..31; identical prefixes would mean reuse
        assertFalse(first.copyOfRange(4, 32).contentEquals(second.copyOfRange(4, 32)))
    }

    @Test
    fun ciphertextDoesNotLeakPlaintext() {
        val envelope = SyncBlobCrypto.seal(payload, passphrase)
        assertFalse(String(envelope, Charsets.ISO_8859_1).contains("Midnight Notes"))
    }
}
