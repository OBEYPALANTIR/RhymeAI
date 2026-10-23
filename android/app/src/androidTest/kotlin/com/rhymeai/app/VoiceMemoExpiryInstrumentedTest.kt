package com.rhymeai.app

import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.recording.RecordingFiles
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
            })
            val memoDir = RecordingFiles.memoDirectory(root, "signal-fixture")
            assertTrue(memoDir.mkdirs())
            // A36: a recording file is named by its id.
            val memoFile = File(memoDir, "${UUID.randomUUID()}.m4a")
            assertTrue(memoFile.createNewFile())
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
            val trash = RecordingFiles.trashDirectory(root, "recording-fixture")
            assertTrue(trash.mkdirs())
            val expired = File(trash, "100__expired.m4a")
            val future = File(trash, "10000__future.m4a")
            assertTrue(expired.createNewFile())
            assertTrue(future.createNewFile())

            assertTrue(service.purgeExpiredTrashedMemos(TRASH_RETENTION_MILLIS + 200L))
            assertFalse(expired.exists())
            assertTrue(future.exists())
            assertTrue(service.purgeExpiredTrashedMemos(TRASH_RETENTION_MILLIS + 20_000L))
            assertFalse(future.exists())
        } finally {
            root.deleteRecursively()
        }
    }
}
