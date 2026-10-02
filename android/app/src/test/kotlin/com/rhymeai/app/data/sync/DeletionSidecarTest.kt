package com.rhymeai.app.data.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class DeletionSidecarTest {
    private val passphrase = "correct horse".toCharArray()
    private val token = "token"

    private class FakeDrive : DriveClient {
        val objects = linkedMapOf<String, Pair<String, ByteArray>>()
        var listFails = false
        var dropWrites = false
        val failDownloads = mutableSetOf<String>()
        private var nextId = 0

        override suspend fun findFileByName(accessToken: String, name: String): DriveFileMetadata? =
            objects.entries.firstOrNull { it.value.first == name }?.let { DriveFileMetadata(it.key, name) }

        override suspend fun listFilesByNamePrefix(accessToken: String, namePrefix: String): List<DriveFileMetadata> {
            if (listFails) throw DriveNetworkException("list failed")
            return objects.filter { it.value.first.startsWith(namePrefix) }.map { DriveFileMetadata(it.key, it.value.first) }
        }

        override suspend fun downloadFile(accessToken: String, fileId: String, maxBytes: Long): ByteArray {
            if (fileId in failDownloads) throw DriveNetworkException("download failed")
            val bytes = objects.getValue(fileId).second
            if (bytes.size > maxBytes) throw DriveNetworkException("too large")
            return bytes
        }

        override suspend fun uploadNewFile(accessToken: String, name: String, mimeType: String, content: ByteArray): String {
            val id = "f${nextId++}"
            if (!dropWrites) objects[id] = name to content
            return id
        }

        override suspend fun updateFile(accessToken: String, fileId: String, mimeType: String, content: ByteArray) {
            if (!dropWrites) objects[fileId] = objects.getValue(fileId).first to content
        }
    }

    private class FakeIdentity(private var id: String) : SidecarWriterIdentity {
        private var nonce: String? = null
        var rotations = 0
        override fun writerId(): String = id
        override fun lastVerifiedNonce(): String? = nonce
        override fun recordVerifiedNonce(nonce: String) { this.nonce = nonce }
        override fun rotate() { rotations++; id = randomHex(16); nonce = null }
    }

    private fun sidecar(drive: FakeDrive, identity: SidecarWriterIdentity, max: Long = DriveSyncService.MAX_SYNC_BLOB_BYTES) =
        DeletionSidecar(drive, identity, max)

    private fun tomb(name: String, sha: String, deletedAt: Long, restoredAt: Long? = null) =
        RecordingTombstone("p1", name, deletedAt, sha, restoredAt)

    private fun manifest(name: String, sha: String, modifiedAt: Long = 100L) =
        RecordingManifestEntry(projectId = "p1", fileName = name, sizeBytes = 1L, modifiedAt = modifiedAt, sha256 = sha)

    @Test
    fun scriptedABFInterleavingKeepsTheVerifiedDeletion() = runBlocking {
        val drive = FakeDrive()
        val a = sidecar(drive, FakeIdentity("a".repeat(32)))
        val b = sidecar(drive, FakeIdentity("b".repeat(32)))

        // A and B both read the (empty) state before either writes.
        assertTrue(a.readAll(token, passphrase) is SidecarRead.Ok)
        assertTrue(b.readAll(token, passphrase) is SidecarRead.Ok)

        // A writes its deletion and verifies it, then goes offline.
        assertEquals(SidecarWrite.Written, a.writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L))))
        val aObjectBefore = drive.objects.values.first { it.first == DeletionSidecar.objectName("a".repeat(32)) }.second.copyOf()

        // B writes its own stale-view union afterwards; it can only touch its own object.
        assertEquals(SidecarWrite.Written, b.writeOwn(token, passphrase, listOf(tomb("other.m4a", "h9", 300L))))
        val aObjectAfter = drive.objects.values.first { it.first == DeletionSidecar.objectName("a".repeat(32)) }.second
        assertContentEquals(aObjectBefore, aObjectAfter)

        // Fresh install F lists everything and still sees A's deletion.
        val f = sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase)
        assertTrue(f is SidecarRead.Ok)
        f as SidecarRead.Ok
        assertEquals(2, f.objectCount)
        assertTrue(f.entries.any { it.suppresses(manifest("take.m4a", "h100")) })
        assertTrue(f.entries.any { it.suppresses(manifest("other.m4a", "h9")) })
    }

    @Test
    fun writerNeverUpdatesAnotherInstallsObject() = runBlocking {
        val drive = FakeDrive()
        sidecar(drive, FakeIdentity("a".repeat(32))).writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L)))
        val idA = drive.objects.keys.single()

        sidecar(drive, FakeIdentity("b".repeat(32))).writeOwn(token, passphrase, listOf(tomb("x.m4a", "hx", 1L)))

        assertEquals(2, drive.objects.size)
        assertEquals(DeletionSidecar.objectName("a".repeat(32)), drive.objects.getValue(idA).first)
    }

    @Test
    fun restoreEventPropagatesAndLaterDeleteWinsAgain() = runBlocking {
        val drive = FakeDrive()
        val a = sidecar(drive, FakeIdentity("a".repeat(32)))
        a.writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L)))
        a.writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L, restoredAt = 300L)))

        val afterRestore = sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase) as SidecarRead.Ok
        assertFalse(afterRestore.entries.any { it.suppresses(manifest("take.m4a", "h100")) })

        a.writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 400L, restoredAt = 300L)))
        val afterDelete = sidecar(drive, FakeIdentity("g".repeat(32))).readAll(token, passphrase) as SidecarRead.Ok
        assertTrue(afterDelete.entries.any { it.suppresses(manifest("take.m4a", "h100")) })
    }

    @Test
    fun wrongPassphraseObjectIsUnavailableNeverEmpty() = runBlocking {
        val drive = FakeDrive()
        sidecar(drive, FakeIdentity("a".repeat(32))).writeOwn(token, "old passphrase".toCharArray(), listOf(tomb("take.m4a", "h100", 200L)))
        sidecar(drive, FakeIdentity("b".repeat(32))).writeOwn(token, passphrase, listOf(tomb("other.m4a", "h9", 300L)))

        val read = sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase)

        assertTrue(read is SidecarRead.Unavailable)
        read as SidecarRead.Unavailable
        assertEquals(1, read.unreadableObjects)
        assertTrue(read.listingComplete)
        assertTrue(read.entries.any { it.fileName == "other.m4a" })
    }

    @Test
    fun malformedAndUndownloadableObjectsAreUnavailable() = runBlocking {
        val drive = FakeDrive()
        drive.objects["g1"] = DeletionSidecar.objectName("c".repeat(32)) to byteArrayOf(1, 2, 3)
        assertEquals(1, (sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase) as SidecarRead.Unavailable).unreadableObjects)

        val drive2 = FakeDrive()
        sidecar(drive2, FakeIdentity("a".repeat(32))).writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L)))
        drive2.failDownloads += drive2.objects.keys.single()
        assertEquals(1, (sidecar(drive2, FakeIdentity("f".repeat(32))).readAll(token, passphrase) as SidecarRead.Unavailable).unreadableObjects)
    }

    @Test
    fun listingFailureIsUnavailableWithoutListingComplete() = runBlocking {
        val drive = FakeDrive().also { it.listFails = true }

        val read = sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase)

        assertTrue(read is SidecarRead.Unavailable)
        assertFalse((read as SidecarRead.Unavailable).listingComplete)
    }

    @Test
    fun duplicateObjectsAreUnionedAndAllRead() = runBlocking {
        val drive = FakeDrive()
        val a = sidecar(drive, FakeIdentity("a".repeat(32)))
        a.writeOwn(token, passphrase, listOf(tomb("one.m4a", "h1", 10L)))
        // A crash-created duplicate of the same writer's object holds different entries.
        val copy = drive.objects.values.first().second
        drive.objects["dup"] = DeletionSidecar.objectName("a".repeat(32)) to copy
        sidecar(drive, FakeIdentity("b".repeat(32))).writeOwn(token, passphrase, listOf(tomb("two.m4a", "h2", 20L)))

        val read = sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase) as SidecarRead.Ok

        assertEquals(3, read.objectCount)
        assertEquals(setOf("one.m4a", "two.m4a"), read.entries.map { it.fileName }.toSet())
    }

    @Test
    fun oversizedOwnObjectIsRejectedBeforeAnyWrite() = runBlocking {
        val drive = FakeDrive()

        val result = sidecar(drive, FakeIdentity("a".repeat(32)), max = 10L)
            .writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L)))

        assertEquals(SidecarWrite.TooLarge, result)
        assertTrue(drive.objects.isEmpty())
    }

    @Test
    fun unverifiedWriteIsReportedNotSuccess() = runBlocking {
        val drive = FakeDrive().also { it.dropWrites = true }

        val result = sidecar(drive, FakeIdentity("a".repeat(32))).writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L)))

        assertEquals(SidecarWrite.NotVerified, result)
    }

    @Test
    fun writeFailurePropagatesSoTheBlobIsNotWritten() = runBlocking {
        val drive = FakeDrive().also { it.listFails = true }

        assertFailsWith<DriveNetworkException> {
            sidecar(drive, FakeIdentity("a".repeat(32))).writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L)))
        }
        // JUnit 4 requires a void test method; assertFailsWith returns the exception.
        Unit
    }

    @Test
    fun cloneWritingUnderOurIdRotatesTheIdAndKeepsTheOldObjectReadable() = runBlocking {
        val drive = FakeDrive()
        val original = FakeIdentity("a".repeat(32))
        sidecar(drive, original).writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L)))
        // A clone shares the id but holds its own nonce state, then writes.
        sidecar(drive, FakeIdentity("a".repeat(32))).writeOwn(token, passphrase, listOf(tomb("clone.m4a", "hc", 300L)))

        val read = sidecar(drive, original).readAll(token, passphrase)

        assertEquals(1, original.rotations)
        assertNotEquals("a".repeat(32), original.writerId())
        assertTrue(read is SidecarRead.Ok)
        assertTrue((read as SidecarRead.Ok).entries.any { it.fileName == "clone.m4a" })
    }

    @Test
    fun driveNamesAndCiphertextCarryNoPlaintextNames() = runBlocking {
        val drive = FakeDrive()
        sidecar(drive, FakeIdentity("a".repeat(32))).writeOwn(token, passphrase, listOf(tomb("secret-song-take.m4a", "h100", 200L)))

        val (name, bytes) = drive.objects.values.single()

        assertTrue(name.startsWith(DeletionSidecar.NAME_PREFIX))
        assertFalse(name.contains("secret-song"))
        assertFalse(String(bytes, Charsets.ISO_8859_1).contains("secret-song"))
    }

    @Test
    fun pagesAreFollowedAndPartialListingsFailClosed() {
        val pages: Map<String?, Pair<List<Int>, String?>> =
            mapOf(null to (listOf(1, 2) to "t1"), "t1" to (listOf(3) to "t2"), "t2" to (listOf(4) to null))
        assertEquals(listOf(1, 2, 3, 4), collectAllPages(20) { pages.getValue(it) })

        assertFailsWith<DriveNetworkException> {
            collectAllPages<Int>(20) { listOf(1) to "same" }
        }
        assertFailsWith<DriveNetworkException> {
            var n = 0
            collectAllPages<Int>(3) { listOf(1) to "t${n++}" }
        }
    }

    @Test
    fun serializerRunsSyncAndRestoreOneAtATime() = runBlocking {
        val serializer = SyncSerializer()
        val active = AtomicInteger(0)
        val maxActive = AtomicInteger(0)

        val jobs = (1..4).map {
            async(Dispatchers.Default) {
                serializer.run {
                    val now = active.incrementAndGet()
                    maxActive.updateAndGet { m -> maxOf(m, now) }
                    delay(20)
                    active.decrementAndGet()
                }
            }
        }
        jobs.awaitAll()

        assertEquals(1, maxActive.get())
    }

    @Test
    fun existingVerifiedRecordsSurviveAWriteFromDamagedOrMissingLocalState() = runBlocking {
        val drive = FakeDrive()
        val a = sidecar(drive, FakeIdentity("a".repeat(32)))
        assertEquals(SidecarWrite.Written, a.writeOwn(token, passphrase, listOf(tomb("old.m4a", "h1", 100L))))

        // Local state was lost, so only a brand-new deletion is passed in.
        assertEquals(SidecarWrite.Written, a.writeOwn(token, passphrase, listOf(tomb("new.m4a", "h2", 200L))))

        val read = sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase) as SidecarRead.Ok
        assertTrue(read.entries.any { it.suppresses(manifest("old.m4a", "h1")) })
        assertTrue(read.entries.any { it.suppresses(manifest("new.m4a", "h2")) })
        assertEquals(1, drive.objects.size)
    }

    @Test
    fun explicitRestoreIsKeptWhenMergedWithTheExistingObject() = runBlocking {
        val drive = FakeDrive()
        val a = sidecar(drive, FakeIdentity("a".repeat(32)))
        a.writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L)))

        a.writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L, restoredAt = 300L)))

        val read = sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase) as SidecarRead.Ok
        assertFalse(read.entries.any { it.suppresses(manifest("take.m4a", "h100")) })
    }

    @Test
    fun unreadableExistingOwnObjectIsNeverOverwritten() = runBlocking {
        val drive = FakeDrive()
        val a = sidecar(drive, FakeIdentity("a".repeat(32)))
        a.writeOwn(token, "another passphrase".toCharArray(), listOf(tomb("old.m4a", "h1", 100L)))
        val before = drive.objects.values.single().second.copyOf()

        val result = a.writeOwn(token, passphrase, listOf(tomb("new.m4a", "h2", 200L)))

        assertEquals(SidecarWrite.ExistingUnreadable, result)
        assertContentEquals(before, drive.objects.values.single().second)
    }

    @Test
    fun unreadableExistingOwnObjectFailsClosedWithoutRotatingTheIdentity() = runBlocking {
        val drive = FakeDrive()
        val identity = FakeIdentity("a".repeat(32))
        val a = sidecar(drive, identity)
        a.writeOwn(token, "another passphrase".toCharArray(), listOf(tomb("old.m4a", "h1", 100L)))

        assertEquals(SidecarWrite.ExistingUnreadable, a.writeOwn(token, passphrase, listOf(tomb("new.m4a", "h2", 200L))))

        assertEquals(0, identity.rotations)
        assertEquals(1, drive.objects.size)
    }

    @Test
    fun transientDownloadFailureOfTheExistingOwnObjectThrowsInsteadOfClaimingItIsUnreadable() = runBlocking {
        val drive = FakeDrive()
        val identity = FakeIdentity("a".repeat(32))
        val a = sidecar(drive, identity)
        a.writeOwn(token, passphrase, listOf(tomb("old.m4a", "h1", 100L)))
        val ownId = drive.objects.keys.single()
        val before = drive.objects.getValue(ownId).second.copyOf()
        drive.failDownloads += ownId

        assertFailsWith<DriveNetworkException> { a.writeOwn(token, passphrase, listOf(tomb("new.m4a", "h2", 200L))) }

        assertContentEquals(before, drive.objects.getValue(ownId).second)
        assertEquals(1, drive.objects.size)
        assertEquals(0, identity.rotations)

        // Once the download works again the same call succeeds and the older record is merged in, not dropped.
        drive.failDownloads.clear()
        assertEquals(SidecarWrite.Written, a.writeOwn(token, passphrase, listOf(tomb("new.m4a", "h2", 200L))))
        val read = sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase) as SidecarRead.Ok
        assertTrue(read.entries.any { it.suppresses(manifest("old.m4a", "h1")) })
        assertTrue(read.entries.any { it.suppresses(manifest("new.m4a", "h2")) })
    }

    @Test
    fun readAllStillTreatsADownloadFailureAsUnreadableAndPausesRestore() = runBlocking {
        val drive = FakeDrive()
        sidecar(drive, FakeIdentity("a".repeat(32))).writeOwn(token, passphrase, listOf(tomb("take.m4a", "h100", 200L)))
        drive.failDownloads += drive.objects.keys.single()

        val read = sidecar(drive, FakeIdentity("f".repeat(32))).readAll(token, passphrase)

        assertTrue(read is SidecarRead.Unavailable)
        assertEquals(1, (read as SidecarRead.Unavailable).unreadableObjects)
    }
}
