package com.rhymeai.app.data.sync

import com.rhymeai.app.data.model.SongProject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
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
    fun millisecondPrecisionSurvivesTheRoundTripSoAnOlderTombstoneCannotWin() {
        val entry = RecordingManifestEntry("p1", "take.m4a", sizeBytes = 3L, modifiedAt = 0L,
            sha256 = BackupManifest.sha256Hex(byteArrayOf(1, 2, 3)), uploadedAt = 5_900L)
        val tombstone = SyncDeletion("p1", "take.m4a", 5_500L, recordingId = entry.id)
        val blob = SyncBlob(
            projects = listOf(SongProject(id = "p1", title = "t", updatedAt = 1_234_567L)),
            recordings = listOf(entry)
        )

        val decoded = BackupManifest.decode(BackupManifest.encode(blob, 1_792_702_991_123L, "device"))

        assertEquals(5_900L, decoded.recordings.single().uploadedAt)
        assertEquals(1_234_567L, decoded.projects.single().updatedAt)
        assertEquals(1_792_702_991_123L, decoded.savedAt)
        assertEquals(listOf(entry.id), SyncMerger.merge(decoded, SyncBlob(deletions = listOf(tombstone))).recordings.map { it.id })
    }

    @Test
    fun recordingNamesAreRawAndDistinctFromTheEncryptedOnes() {
        assertEquals("rec_0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", BackupManifest.recordingDriveName("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"))
        assertEquals("rec_p1_take.m4a.enc", RecordingManifestEntry.driveNameFor("p1", "take.m4a"))
        assertEquals("2026-10-22T21:03:11.999Z", BackupManifest.isoMillis(1_792_702_991_999L))
        assertEquals("2026-10-22T21:03:11.000Z", BackupManifest.isoMillis(1_792_702_991_000L))
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

    @Test
    fun theFixturesFileNamesAreDisplayNamesAndFilesAreNamedById() {
        val uploaded = fixture.getValue("uploadedBytes").jsonPrimitive.content.toByteArray(Charsets.UTF_8)
        val dir = kotlin.io.path.createTempDirectory("rhymeai-fixture").toFile()
        try {
            for (entry in BackupManifest.decode(uploaded).recordings) {
                val record = entry.toRecord(RecordingRecord.RESTORED, null)
                assertEquals(entry.fileName, record.displayName)
                assertEquals(entry.fileName, record.toEntry().fileName)
                assertEquals("${entry.id}.m4a", RecordingFileStore.targetFile(dir, entry.projectId, entry.id, entry.fileName).name)
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun aTrashEntryCarriesBothRepairFlagsAndAbsentTimesReadAsUnknown() {
        val trashed = com.rhymeai.app.data.model.TrashedSongProject(
            SongProject(id = "t", title = "T", updatedAt = 10L, precedenceRepaired = true), deletedAt = 20L, deletedAtRepaired = true
        )
        val bytes = BackupManifest.encode(SyncBlob(projects = listOf(SongProject(id = "p", updatedAt = 5L)), trashed = listOf(trashed)), 1_000L, "x")
        val text = String(bytes)
        // A38: the Trash entry's own time and its song's time each carry their flag; a real time carries none.
        assertTrue("\"trashedAtRepaired\":true" in text && text.split("\"precedenceRepaired\":true").size == 2, text)
        val back = BackupManifest.decode(bytes).trashed.single()
        assertEquals(true to true, back.project.precedenceRepaired to back.deletedAtRepaired)

        // A correctly hashed manifest without updatedAt or trashedAt reads them as unknown (0); a wrong type is refused.
        fun rehash(edit: (JsonObject) -> JsonObject): ByteArray {
            val root = Json.parseToJsonElement(text).jsonObject
            val body = edit(JsonObject(root - BackupManifest.HASH_KEY))
            val hash = BackupManifest.sha256Hex(BackupManifest.canonical(body).toByteArray())
            return BackupManifest.canonical(JsonObject(body + (BackupManifest.HASH_KEY to JsonPrimitive(hash)))).toByteArray()
        }
        fun edited(array: String, change: (JsonObject) -> JsonObject) = rehash { body ->
            JsonObject(body + (array to kotlinx.serialization.json.JsonArray(body.getValue(array).jsonArray.map { change(it.jsonObject) })))
        }
        assertEquals(0L, BackupManifest.decode(edited("projects") { JsonObject(it - "updatedAt") }).projects.single().updatedAt)
        val noTimes = BackupManifest.decode(edited("trashed") { JsonObject(it - "trashedAt" - "updatedAt") }).trashed.single()
        assertEquals(0L to 0L, noTimes.deletedAt to noTimes.project.updatedAt)
        assertFailsWith<DamagedBackupException> {
            BackupManifest.decode(edited("projects") { JsonObject(it + ("updatedAt" to JsonPrimitive("soon"))) })
        }
    }
    @Test
    fun aDeletionTimeThatIsNegativeOrNotANumberIsRefusedAndAnAbsentOneIsUnknown() {
        // Only zero or absent is unknown; a negative time or a wrong type refuses the whole manifest.
        val text = String(BackupManifest.encode(SyncBlob(deletions = listOf(SyncDeletion("p", deletedAt = 5L))), 1_000L, "x"))
        fun withDeletedAt(value: kotlinx.serialization.json.JsonElement?): ByteArray {
            val root = Json.parseToJsonElement(text).jsonObject
            val body = JsonObject(root - BackupManifest.HASH_KEY).let { b ->
                JsonObject(b + ("deletions" to kotlinx.serialization.json.JsonArray(b.getValue("deletions").jsonArray.map {
                    val d = JsonObject(it.jsonObject - "deletedAt")
                    if (value == null) d else JsonObject(d + ("deletedAt" to value))
                })))
            }
            val hash = BackupManifest.sha256Hex(BackupManifest.canonical(body).toByteArray())
            return BackupManifest.canonical(JsonObject(body + (BackupManifest.HASH_KEY to JsonPrimitive(hash)))).toByteArray()
        }
        assertFailsWith<DamagedBackupException> { BackupManifest.decode(withDeletedAt(JsonPrimitive(-5L))) }
        assertFailsWith<DamagedBackupException> { BackupManifest.decode(withDeletedAt(JsonPrimitive("5"))) }
        assertEquals(0L, BackupManifest.decode(withDeletedAt(null)).deletions.single().deletedAt)
        assertEquals(0L, BackupManifest.decode(withDeletedAt(JsonPrimitive(0L))).deletions.single().deletedAt)
    }
}
