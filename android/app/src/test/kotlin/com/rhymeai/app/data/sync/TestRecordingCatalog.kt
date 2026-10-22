package com.rhymeai.app.data.sync

import com.rhymeai.app.data.recording.RecordingCatalog
import com.rhymeai.app.data.recording.RecordingTransitions
import kotlinx.coroutines.runBlocking
import java.io.File
import java.io.IOException

/** In-memory recording records; [failWrites] injects a metadata write failure. */
class MemoryCatalog : RecordingCatalog {
    var records: List<RecordingRecord> = emptyList()
    var failWrites = false

    override suspend fun recordingRecords(): List<RecordingRecord> = records

    override suspend fun updateRecordingRecords(transform: (List<RecordingRecord>) -> List<RecordingRecord>) {
        if (failWrites) throw IOException("injected metadata write failure")
        records = transform(records)
    }
}

/** Live recordings on disk, through the real snapshot with a throwaway or given catalog. */
internal fun snapshotLocalRecordingFiles(
    filesDir: File,
    pendingDeletionIds: Set<String>,
    catalog: RecordingCatalog = MemoryCatalog()
): List<LocalRecordingFile> =
    runBlocking { RecordingTransitions.snapshot(catalog, filesDir, pendingDeletionIds) }.filterNot { it.inTrash }
