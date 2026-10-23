package com.rhymeai.app

import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.recording.RecordingCatalog
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.sync.RecordingRecord
import com.rhymeai.app.service.VoiceMemoService
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceMemoExpiryInstrumentedTest {
    /** In-memory records; every transition needs them (A23). */
    private class Catalog : RecordingCatalog {
        var records = listOf<RecordingRecord>()
        override suspend fun recordingRecords() = records
        override suspend fun updateRecordingRecords(transform: (List<RecordingRecord>) -> List<RecordingRecord>) {
            records = transform(records)
        }
    }

    @Test
    fun trashRestoreAndDeleteAnnounceTrashChanges() = runBlocking {
        // The purge scheduler rescans recording expiries on these events; nothing in the
        // preferences store changes when a recording file moves, so the service must say so.
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        check(target.packageName == "com.rhymeai.app.motionqa") { "This fixture requires the isolated QA app." }
        val root = File(target.cacheDir, "memo-signal-${UUID.randomUUID()}")
        assertTrue(root.mkdirs())
        try {
            val service = VoiceMemoService(object : ContextWrapper(target) {
                override fun getFilesDir(): File = root
            }).also { it.catalog = Catalog() }
            val memoDir = RecordingFiles.memoDirectory(root, "signal-fixture")
            assertTrue(memoDir.mkdirs())
            // A36: a recording file is named by its id.
            val memoFile = File(memoDir, "${UUID.randomUUID()}.m4a")
            memoFile.writeText("take")
            val memo = service.memosForProject("signal-fixture").single { it.file.name == memoFile.name }

            val events = mutableListOf<Unit>()
            val collector = launch { service.trashChanges.take(3).toList(events) }
            yield()

            val trashed = checkNotNull(service.trashMemo(memo))
            assertTrue(service.restoreTrashedMemo(trashed))
            val again = checkNotNull(service.trashMemo(service.memosForProject("signal-fixture").single()))
            assertTrue(service.permanentlyDeleteTrashedMemo(again))
            collector.join()
            assertEquals(3, events.size)

            // A failed move announces nothing.
            assertFalse(service.restoreTrashedMemo(again))
            assertEquals(3, events.size)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun expiredRecordingIsDeletedIndependentlyOfFutureRecording() = runBlocking {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        check(target.packageName == "com.rhymeai.app.motionqa") { "This fixture requires the isolated QA app." }
        val root = File(target.cacheDir, "memo-expiry-${UUID.randomUUID()}")
        assertTrue(root.mkdirs())
        try {
            val service = VoiceMemoService(object : ContextWrapper(target) {
                override fun getFilesDir(): File = root
            })
            val catalog = Catalog()
            service.catalog = catalog
            // The launch check adopts what is on disk, as the app does.
            service.maintenance = { com.rhymeai.app.data.recording.RecordingTransitions.migrate(catalog, root); Unit }
            val start = System.currentTimeMillis()
            val trash = RecordingFiles.trashDirectory(root, "recording-fixture")
            assertTrue(trash.mkdirs())
            val expired = File(trash, "100__expired.m4a").apply { writeText("expired") }
            val future = File(trash, "10000__future.m4a").apply { writeText("future") }
            // T2.35: a Trash file whose time is unknown gets the time it was first seen, never an epoch deadline.
            val unknown = File(trash, "${UUID.randomUUID()}.m4a").apply { writeText("unknown time") }
            service.runMaintenance()
            suspend fun holding(text: String) = service.trashedMemos().singleOrNull { it.file.readText() == text }

            assertTrue(service.purgeExpiredTrashedMemos(TRASH_RETENTION_MILLIS + 200L))
            assertEquals(null, holding("expired"))
            assertTrue(holding("future") != null)
            assertTrue(service.purgeExpiredTrashedMemos(TRASH_RETENTION_MILLIS + 20_000L))
            assertEquals(null, holding("future"))
            val kept = checkNotNull(holding("unknown time"))
            assertTrue(kept.deleteAfter >= start + TRASH_RETENTION_MILLIS)
            assertEquals(kept.deleteAfter, service.nextTrashedMemoExpiry())
            assertFalse(expired.exists() || future.exists())
            assertEquals(unknown.canonicalFile, kept.file.canonicalFile)
        } finally {
            root.deleteRecursively()
        }
    }
}
