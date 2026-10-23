package com.rhymeai.app.data.sync

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** T3.25–T3.32: older backup formats as their writers stored them, read from literal JSON. */
class HistoricalFormatsTest {
    private val legacyJson = Json { ignoreUnknownKeys = true }
    private val bytes = "take".toByteArray()
    private val sha = BackupManifest.sha256Hex(bytes)

    @Test
    fun aV1BackupWithoutTimesReadsThemAsUnknown() {
        val blob = legacyJson.decodeFromString<SyncBlob>(
            """{"version":1,"projects":[{"id":"s1","title":"Old"}],"trashed":[{"project":{"id":"t1","title":"T","updatedAt":5}}]}"""
        )
        assertEquals(0L, blob.projects.single().updatedAt)
        assertEquals(0L, blob.trashed.single().deletedAt)
        assertEquals(5L, blob.trashed.single().project.updatedAt)
        assertTrue(blob.deletions.isEmpty() && blob.recordings.isEmpty())
        // v1 never had tombstones, and an identity is never invented.
        assertFailsWith<SerializationException> { legacyJson.decodeFromString<SyncBlob>("""{"version":1,"deletions":[]}""") }
        assertFailsWith<SerializationException> { legacyJson.decodeFromString<SyncBlob>("""{"version":1,"projects":[{"title":"No id"}]}""") }
    }

    @Test
    fun aV2BackupKeepsItsSongTombstones() {
        val blob = legacyJson.decodeFromString<SyncBlob>(
            """{"version":2,"projects":[{"id":"s1","title":"x","updatedAt":10}],"deletions":[{"projectId":"s2","deletedAt":20}]}"""
        )
        assertEquals(10L, blob.projects.single().updatedAt)
        assertTrue(blob.deletions.single().isSongTombstone)
        assertFailsWith<SerializationException> { legacyJson.decodeFromString<SyncBlob>("""{"version":2,"projects":[]}""") }
    }

    @Test
    fun aV3RecordingWithoutAnIdGetsTheDerivedLegacyId() {
        val blob = legacyJson.decodeFromString<SyncBlob>(
            """{"version":3,"deletions":[{"projectId":"song","fileName":"gone.m4a","deletedAt":30}],""" +
                """"recordings":[{"projectId":"song","fileName":"take.m4a","sizeBytes":4,"modifiedAt":1,"sha256":"$sha"}]}"""
        )
        val entry = blob.recordings.single()
        assertEquals(RecordingManifestEntry.legacyRecordingId("song", "take.m4a", sha), entry.id)
        assertEquals(null, blob.deletions.single().recordingId)
    }

    /** A manifest of the first v4 builds, whose recordings carried no id. */
    private fun idLessManifest(): ByteArray {
        val entry = RecordingManifestEntry(projectId = "song", fileName = "take.m4a", sizeBytes = 4L, modifiedAt = 0L, sha256 = sha, uploadedAt = 900L)
        val text = String(BackupManifest.encode(SyncBlob(recordings = listOf(entry)), 1_000L, "early"))
        val root = Json.parseToJsonElement(text).jsonObject
        val body = JsonObject(root - BackupManifest.HASH_KEY).let { body ->
            JsonObject(body + ("recordings" to JsonArray(body.getValue("recordings").jsonArray.map { JsonObject(it.jsonObject - "id") })))
        }
        val hash = BackupManifest.sha256Hex(BackupManifest.canonical(body).toByteArray())
        return BackupManifest.canonical(JsonObject(body + (BackupManifest.HASH_KEY to JsonPrimitive(hash)))).toByteArray()
    }

    @Test
    fun anEarlyV4ManifestWithoutRecordingIdsDerivesTheLegacyId() {
        val manifest = idLessManifest()
        assertTrue("\"id\"" !in String(manifest))

        val entry = BackupManifest.decode(manifest).recordings.single()

        assertEquals(RecordingManifestEntry.legacyRecordingId("song", "take.m4a", sha), entry.id)
        assertEquals(900L, entry.uploadedAt)
    }

    @Test
    fun anEarlyV4ArchiveWithoutRecordingIdsReadsItsAudioUnderTheDerivedId() {
        val file = kotlin.io.path.createTempFile("early-archive", ".zip").toFile()
        try {
            ZipOutputStream(file.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry(BackupArchive.MANIFEST_ENTRY)); zip.write(idLessManifest()); zip.closeEntry()
                zip.putNextEntry(ZipEntry("recordings/song/take.m4a")); zip.write(bytes); zip.closeEntry()
            }

            val contents = BackupArchive.read(file)

            val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", sha)
            assertEquals(id, contents.manifest.recordings.single().id)
            assertContentEquals(bytes, contents.recordings.getValue(id))
            assertTrue(contents.damagedIds.isEmpty())
        } finally {
            File(file.path).delete()
        }
    }
    @Test
    fun aTombstoneWithoutAValidTimeIsRefusedNeverGivenOne() {
        // A33/A41: no deletion time is ever invented; the whole backup is refused instead.
        assertFailsWith<SerializationException> {
            legacyJson.decodeFromString<SyncBlob>("""{"version":2,"projects":[{"id":"s1","updatedAt":10}],"deletions":[{"projectId":"s1"}]}""")
        }
        assertFailsWith<IllegalArgumentException> {
            legacyJson.decodeFromString<SyncBlob>("""{"version":2,"projects":[],"deletions":[{"projectId":"s1","deletedAt":0}]}""")
        }
    }
}
