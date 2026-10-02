package com.rhymeai.app

import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.service.VoiceMemoService
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceMemoExpiryInstrumentedTest {
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
