package com.rhymeai.app.data.sync

import com.rhymeai.app.data.model.SongProject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assume.assumeTrue
import java.io.File
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** Pins manifest v4 to shared/fixtures/sync-manifest-v4.json, which iOS reads too. */
class BackupManifestTest {
    private fun repoFile(path: String): File =
        sequenceOf("../../$path", "../$path", path).map(::File).first(File::isFile)

    private fun repoFileOrNull(path: String): File? =
        sequenceOf("../../$path", "../$path", path).map(::File).firstOrNull(File::isFile)

    private val fixture by lazy {
        Json.parseToJsonElement(repoFile("shared/fixtures/sync-manifest-v4.json").readText()).jsonObject
    }
    private val manifest get() = fixture.getValue("manifest").jsonObject

    @Test
    fun canonicalFormAndHashMatchTheSharedFixture() {
        val canonical = BackupManifest.canonical(JsonObject(manifest - BackupManifest.HASH_KEY))
        assertEquals(fixture.getValue("canonical").jsonPrimitive.content, canonical)
        val hash = BackupManifest.sha256Hex(canonical.toByteArray(Charsets.UTF_8))
        assertEquals(fixture.getValue("manifestSha256").jsonPrimitive.content, hash)
        assertEquals(hash, manifest.getValue(BackupManifest.HASH_KEY).jsonPrimitive.content)
        // Non-ASCII is written as UTF-8, never escaped; quotes and newlines are.
        assertTrue("Café Nights" in canonical && "夜" in canonical)
        assertTrue("""\"stay\"""" in canonical && """\nNeon""" in canonical)
    }

    @Test
    fun fixtureDecodesAndReEncodesByteForByte() {
        val uploaded = fixture.getValue("uploadedBytes").jsonPrimitive.content.toByteArray(Charsets.UTF_8)
        val blob = BackupManifest.decode(uploaded)

        assertEquals(listOf("Café Nights", "Plain Song"), blob.projects.map { it.title })
        assertEquals(1, blob.trashed.size)
        assertEquals(2, blob.recordings.size)
        assertEquals(listOf("memo_20261001_090000.m4a", null), blob.deletions.map { it.fileName })
        assertEquals("6f1c2b9e-4d3a-4f8e-9a51-2c7d8e0b1f34", blob.savedByClientId)
        assertContentEquals(uploaded, BackupManifest.encode(blob, blob.savedAt, blob.savedByClientId))
    }

    @Test
    fun prettyPrintedUploadIsAcceptedBecauseTheHashCoversTheCanonicalForm() {
        val pretty = Json { prettyPrint = true }.encodeToString(JsonObject.serializer(), manifest)
        assertEquals(2, BackupManifest.decode(pretty.toByteArray(Charsets.UTF_8)).projects.size)
    }

    @Test
    fun hashMismatchIsRefused() {
        val projects = manifest.getValue("projects").toString().replace("Line two", "Line 2")
        val tampered = JsonObject(manifest + ("projects" to Json.parseToJsonElement(projects)))
        val error = assertFailsWith<DamagedBackupException> {
            BackupManifest.decode(tampered.toString().toByteArray(Charsets.UTF_8))
        }
        assertEquals("Backup file is damaged; it was not merged.", error.message)
        assertFailsWith<DamagedBackupException> {
            BackupManifest.decode(JsonObject(manifest - BackupManifest.HASH_KEY).toString().toByteArray())
        }
        assertFailsWith<DamagedBackupException> { BackupManifest.decode("not json".toByteArray()) }
        assertFailsWith<DamagedBackupException> { BackupManifest.decode(byteArrayOf(0xC3.toByte(), 0x28)) }
    }

    @Test
    fun newerVersionIsRefusedEvenWithAValidHash() {
        val body = JsonObject(manifest - BackupManifest.HASH_KEY + ("version" to JsonPrimitive(5)))
        val hash = BackupManifest.sha256Hex(BackupManifest.canonical(body).toByteArray())
        val v5 = JsonObject(body + (BackupManifest.HASH_KEY to JsonPrimitive(hash)))
        assertEquals(5, assertFailsWith<UnsupportedBackupVersionException> {
            BackupManifest.decode(v5.toString().toByteArray())
        }.version)
    }

    @Test
    fun hashedButInvalidIdentitiesAreStillRefused() {
        val project = SongProject(id = "../escape", title = "t", lyrics = "", theme = "", updatedAt = 1L)
        val body = JsonObject(
            manifest - BackupManifest.HASH_KEY + ("projects" to Json.parseToJsonElement(
                """[{"id":"${project.id}","title":"t","lyrics":"","theme":"","updatedAt":1}]"""
            ))
        )
        val hash = BackupManifest.sha256Hex(BackupManifest.canonical(body).toByteArray())
        assertFailsWith<DamagedBackupException> {
            BackupManifest.decode(JsonObject(body + (BackupManifest.HASH_KEY to JsonPrimitive(hash))).toString().toByteArray())
        }
    }

    @Test
    fun canonicalEscapesOnlyTheContractCharactersAndSortsKeysByCodePoint() {
        // U+FF5E sorts before U+1F3B5 by code point but after it by UTF-16 unit.
        val value = Json.parseToJsonElement("""{"b":"tab\tbell\u0007slash\\","a":[1,-2,null,true],"🎵":0,"～":1,"z":"é"}""")
        assertEquals(
            "{\"a\":[1,-2,null,true],\"b\":\"tab\\tbell\\u0007slash\\\\\",\"z\":\"é\",\"～\":1,\"🎵\":0}",
            BackupManifest.canonical(value)
        )
        assertFailsWith<IllegalArgumentException> { BackupManifest.canonical(Json.parseToJsonElement("1.5")) }
    }

    @Test
    fun recordingNamesAreRawAndDistinctFromTheEncryptedOnes() {
        assertEquals("rec_p1_take.m4a", BackupManifest.recordingDriveName("p1", "take.m4a"))
        assertEquals("rec_p1_take.m4a.enc", RecordingManifestEntry.driveNameFor("p1", "take.m4a"))
        assertEquals("2026-10-22T21:03:11Z", BackupManifest.isoSeconds(1_792_702_991_999L))
    }

    @Test
    fun iosFixtureCopyMatchesTheSharedFixture() {
        val iosCopy = repoFileOrNull("Writers Block/Writers BlockTests/sync-manifest-v4.json")
        assumeTrue("iOS copy of sync-manifest-v4.json is not in this checkout yet; drift check skipped.", iosCopy != null)
        assertTrue(
            repoFile("shared/fixtures/sync-manifest-v4.json").readBytes().contentEquals(iosCopy!!.readBytes()),
            "iOS fixture copy differs from shared/fixtures/sync-manifest-v4.json"
        )
    }
}
