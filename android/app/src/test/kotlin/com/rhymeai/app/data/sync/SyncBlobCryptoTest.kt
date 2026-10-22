package com.rhymeai.app.data.sync

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.security.MessageDigest
import org.junit.Test

class SyncBlobCryptoTest {

    private val payload = """{"version":1,"projects":[{"title":"Midnight Notes"}]}""".toByteArray()
    private val passphrase = "correct horse battery staple".toCharArray()
    private val goldenPlaintext = """{"version":1,"projects":[],"trashed":[],"recordings":[],"savedAt":1700000000000,"savedByClientId":"android-fixture"}""".toByteArray()
    private val goldenEnvelopeBase64 = "UkFJMQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhtizcOcwuED9qmh1u+pIuacjCXfzEdC4XqsUgnAZ08InG+/2sOGiVfCbTNTgVs/qDX5tg+Xq/8BEH3xh/kmBcKKyayJPnin4qkQQO5xj50WFhaXKsgIOrAWlBrJcXMfe1Y6EmdzpzG87TFCQgajLtF4GAU5Pgh+VRicHt164bxqXJ5xxeE="

    @Test
    fun sealedEnvelopeRoundTripsWithSamePassphrase() {
        val envelope = LegacyEnvelopes.seal(payload, passphrase)
        assertArrayEquals(payload, SyncBlobCrypto.open(envelope, passphrase))
    }

    @Test
    fun reportedEnvelopeSizeMatchesSealedBytes() {
        val envelope = LegacyEnvelopes.seal(payload, passphrase)

        assertEquals(envelope.size.toLong(), SyncBlobCrypto.envelopeSizeForPlaintext(payload.size.toLong()))
    }

    @Test
    fun opensSharedRAI1GoldenFixture() {
        val envelope = Base64.getDecoder().decode(goldenEnvelopeBase64)
        assertArrayEquals(goldenPlaintext, SyncBlobCrypto.open(envelope, passphrase))
    }

    /**
     * Cross-platform pin: this exact base64 envelope and passphrase are the RAI1
     * golden vector held by the iOS BackupCoreTests (opensAndroidCompatibleRAI1Fixture /
     * deterministicSealMatchesRAI1GoldenVector). Opening it here to the expected JSON
     * proves Android's PBKDF2/AES-GCM/envelope-layout stays byte-compatible with iOS —
     * any KDF, GCM, or layout drift on either side breaks this test.
     */
    @Test
    fun opensIosGoldenVectorToExpectedJson() {
        val envelope = Base64.getDecoder().decode(goldenEnvelopeBase64)
        val expectedJson =
            """{"version":1,"projects":[],"trashed":[],"recordings":[],"savedAt":1700000000000,"savedByClientId":"android-fixture"}"""

        val opened = SyncBlobCrypto.open(envelope, passphrase)

        assertEquals(expectedJson, String(opened, Charsets.UTF_8))
    }

    @Test
    fun deterministicSealMatchesSharedRAI1GoldenFixture() {
        val salt = ByteArray(16) { it.toByte() }
        val iv = ByteArray(12) { (0x10 + it).toByte() }

        val envelope = LegacyEnvelopes.seal(goldenPlaintext, passphrase, salt, iv)

        assertArrayEquals(Base64.getDecoder().decode(goldenEnvelopeBase64), envelope)
    }


    @Test
    fun nonAsciiPassphraseFailsBeforeDerivation() {
        assertThrows(IllegalArgumentException::class.java) {
            LegacyEnvelopes.seal(payload, "café".toCharArray())
        }
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(Base64.getDecoder().decode(goldenEnvelopeBase64), "café".toCharArray())
        }
    }
    @Test
    fun wrongPassphraseFailsClosed() {
        val envelope = LegacyEnvelopes.seal(payload, passphrase)
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(envelope, "not the passphrase".toCharArray())
        }
    }

    @Test
    fun tamperedCiphertextFailsAuthentication() {
        val envelope = LegacyEnvelopes.seal(payload, passphrase)
        envelope[envelope.size - 1] = (envelope.last().toInt() xor 0x01).toByte()
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(envelope, passphrase)
        }
    }

    @Test
    fun tamperedHeaderSaltFailsAuthentication() {
        val envelope = LegacyEnvelopes.seal(payload, passphrase)
        envelope[6] = (envelope[6].toInt() xor 0x01).toByte() // inside the salt
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.open(envelope, passphrase)
        }
    }

    @Test
    fun unrecognizedMagicIsRejectedBeforeDecryption() {
        val envelope = LegacyEnvelopes.seal(payload, passphrase)
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
        val first = LegacyEnvelopes.seal(payload, passphrase)
        val second = LegacyEnvelopes.seal(payload, passphrase)
        assertFalse(first.contentEquals(second))
        // salt+IV live in bytes 4..31; identical prefixes would mean reuse
        assertFalse(first.copyOfRange(4, 32).contentEquals(second.copyOfRange(4, 32)))
    }

    @Test
    fun ciphertextDoesNotLeakPlaintext() {
        val envelope = LegacyEnvelopes.seal(payload, passphrase)
        assertFalse(String(envelope, Charsets.ISO_8859_1).contains("Midnight Notes"))
    }

    private val referenceVectors by lazy {
        val stream = requireNotNull(javaClass.classLoader!!.getResourceAsStream("sync-envelope-vectors.json"))
        val fixture = Json.parseToJsonElement(stream.bufferedReader().use { it.readText() }).jsonObject
        fixture.getValue("vectors").jsonArray.map { it.jsonObject }
    }

    @Test
    fun manifestUsesRai3WhileRecordingEncryptionRemainsRai1() {
        val v3 = referenceVectors.single { it.getValue("magic").jsonPrimitive.content == "RAI3" }
        val bytes = v3.getValue("plaintext").jsonPrimitive.content.toByteArray(Charsets.UTF_8)
        val manifest = LegacyEnvelopes.sealManifest(bytes, passphrase)
        assertEquals("RAI3", String(manifest, 0, 4, Charsets.US_ASCII))
        assertEquals(3, SyncBlobCrypto.openManifest(manifest, passphrase).version)
        assertArrayEquals(bytes, SyncBlobCrypto.openManifest(manifest, passphrase).plaintext)
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.openManifest(manifest, "wrong passphrase".toCharArray())
        }
        val recording = LegacyEnvelopes.seal(bytes, passphrase)
        assertEquals("RAI1", String(recording, 0, 4, Charsets.US_ASCII))
        assertArrayEquals(bytes, SyncBlobCrypto.open(recording, passphrase))
    }

    @Test
    fun independentPythonVectorsOpenForEveryEnvelopeVersionAndSealByteIdenticallyForWrittenOnes() {
        val salt = ByteArray(16) { it.toByte() }
        val iv = ByteArray(12) { (0x10 + it).toByte() }
        for (vector in referenceVectors) {
            val plaintext = vector.getValue("plaintext").jsonPrimitive.content.toByteArray(Charsets.UTF_8)
            val expected = Base64.getDecoder().decode(vector.getValue("envelope_base64").jsonPrimitive.content)
            val sha = MessageDigest.getInstance("SHA-256").digest(expected).joinToString("") { "%02x".format(it) }
            assertEquals(vector.getValue("envelope_sha256").jsonPrimitive.content, sha)
            val magic = vector.getValue("magic").jsonPrimitive.content
            assertEquals(magic, String(expected, 0, 4, Charsets.US_ASCII))
            // The test writer reproduces the RAI1 and RAI3 vectors; RAI2 was never written by Android.
            when (magic) {
                "RAI1" -> assertArrayEquals(expected, LegacyEnvelopes.seal(plaintext, passphrase, salt, iv))
                "RAI3" -> assertArrayEquals(expected, LegacyEnvelopes.sealManifest(plaintext, passphrase, salt, iv))
            }
            val opened = SyncBlobCrypto.openManifest(expected, passphrase)
            assertEquals(mapOf("RAI1" to 1, "RAI2" to 2, "RAI3" to 3).getValue(magic), opened.version)
            assertArrayEquals(plaintext, opened.plaintext)
        }
        assertArrayEquals(
            Base64.getDecoder().decode(goldenEnvelopeBase64),
            Base64.getDecoder().decode(referenceVectors.single {
                it.getValue("magic").jsonPrimitive.content == "RAI1"
            }.getValue("envelope_base64").jsonPrimitive.content)
        )
    }

    @Test
    fun manifestHeaderBodyAndTagTamperingFailsClosed() {
        for (magic in listOf("RAI2", "RAI3")) manifestTamperingFailsClosed(magic)
    }

    private fun manifestTamperingFailsClosed(magic: String) {
        val original = Base64.getDecoder().decode(referenceVectors.single {
            it.getValue("magic").jsonPrimitive.content == magic
        }.getValue("envelope_base64").jsonPrimitive.content)
        for (index in listOf(3, 5, 21, 32, original.lastIndex)) {
            val tampered = original.clone()
            tampered[index] = (tampered[index].toInt() xor 1).toByte()
            assertThrows(SyncBlobSealException::class.java) {
                SyncBlobCrypto.openManifest(tampered, passphrase)
            }
        }
        val swappedHeader = original.clone()
        swappedHeader[3] = '1'.code.toByte()
        assertThrows(SyncBlobSealException::class.java) {
            SyncBlobCrypto.openManifest(swappedHeader, passphrase)
        }
    }

    @Test
    fun unknownAndTruncatedManifestHeadersAreDistinctFromAuthenticationFailure() {
        val original = Base64.getDecoder().decode(referenceVectors.single {
            it.getValue("magic").jsonPrimitive.content == "RAI2"
        }.getValue("envelope_base64").jsonPrimitive.content)
        for (magic in listOf("RAI4", "RAI9")) {
            val changed = original.clone()
            magic.toByteArray(Charsets.US_ASCII).copyInto(changed)
            assertEquals("Unsupported envelope version", assertThrows(SyncBlobFormatException::class.java) {
                SyncBlobCrypto.openManifest(changed, passphrase)
            }.message)
        }
        val changed = original.clone()
        "XXXX".toByteArray(Charsets.US_ASCII).copyInto(changed)
        assertEquals("Unrecognized envelope format", assertThrows(SyncBlobFormatException::class.java) {
            SyncBlobCrypto.openManifest(changed, passphrase)
        }.message)
        assertEquals("Envelope is truncated", assertThrows(SyncBlobFormatException::class.java) {
            SyncBlobCrypto.openManifest(byteArrayOf('R'.code.toByte()), passphrase)
        }.message)
        assertThrows(SyncBlobFormatException::class.java) {
            SyncBlobCrypto.openManifest(original.copyOfRange(0, 35), passphrase)
        }
    }
}
