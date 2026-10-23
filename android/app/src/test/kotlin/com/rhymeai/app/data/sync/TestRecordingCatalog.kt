package com.rhymeai.app.data.sync

import com.rhymeai.app.data.recording.RecordingCatalog
import com.rhymeai.app.data.recording.RecordingTransitions
import kotlinx.coroutines.runBlocking
import java.io.File
import java.io.IOException

/** In-memory recording records; [failWrites] or [failOnWrite] (1-based, counting changing writes) inject a write failure. */
class MemoryCatalog : RecordingCatalog {
    var records: List<RecordingRecord> = emptyList()
    var failWrites = false
    var failOnWrite: Int? = null
    var deletionsUnreadable = false
    private var writes = 0

    override suspend fun requireDeletionsReadable() {
        if (deletionsUnreadable) throw IOException("injected unreadable tombstones")
    }

    override suspend fun recordingRecords(): List<RecordingRecord> = records

    override suspend fun updateRecordingRecords(transform: (List<RecordingRecord>) -> List<RecordingRecord>) {
        // Like the DataStore-backed catalog, an unchanged list writes nothing.
        val next = transform(records)
        if (next == records) return
        if (failWrites || ++writes == failOnWrite) throw IOException("injected metadata write failure")
        records = next
    }
}

/** Live recordings on disk, through the real snapshot with a throwaway or given catalog. */
internal fun snapshotLocalRecordingFiles(
    filesDir: File,
    pendingDeletionIds: Set<String>,
    catalog: RecordingCatalog = MemoryCatalog()
): List<LocalRecordingFile> =
    runBlocking { RecordingTransitions.snapshot(catalog, filesDir, pendingDeletionIds) }.filterNot { it.inTrash }
