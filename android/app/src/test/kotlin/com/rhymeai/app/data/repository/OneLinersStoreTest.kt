package com.rhymeai.app.data.repository

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.stringPreferencesKey
import com.rhymeai.app.data.model.OneLinersSnapshot
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.util.ProsodyAnalyzer
import com.rhymeai.app.util.RhymeConstraint
import com.rhymeai.app.util.RhymePhonetics
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class OneLinersStoreTest {
    private class Fixture(val directory: File, val scope: CoroutineScope) {
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "store.preferences_pb") }
        val snapshotFile = File(directory, "widget.json")
        val store = OneLinersStore(dataStore, File(directory, "one-liners"), snapshotFile)
        val songs = ProjectRepository(dataStore, object : SecureKeyStore {
            override fun getKey(provider: String) = ""
            override fun setKey(provider: String, key: String) {}
            override fun allKeys(): Map<String, String> = emptyMap()
            override fun clear() {}
        })

        fun pendingTake(name: String = "take.wav", bytes: String = "RIFF-take"): File =
            File(store.pendingRoot, name).apply { parentFile.mkdirs(); writeText(bytes) }
    }

    private fun withStore(block: suspend Fixture.() -> Unit) = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-one-liners").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            Fixture(directory, scope).block()
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun addKeepsNewestFirstAndSearchIgnoresCase() = withStore {
        store.add("  Midnight rain on a tin roof ", now = 1_000L)
        store.add("Coffee gone cold", now = 2_000L)

        val lines = store.all()
        assertEquals(listOf("Coffee gone cold", "Midnight rain on a tin roof"), lines.map { it.text })
        assertEquals(listOf("Midnight rain on a tin roof"), OneLinersStore.filter(lines, "RAIN").map { it.text })
        assertEquals(lines, OneLinersStore.filter(lines, "   "))
        assertTrue(OneLinersStore.filter(lines, "nothing like this").isEmpty())
    }

    @Test
    fun prosodyIsCachedOnSaveAndFollowsEdits() = withStore {
        val text = "Coffee gone cold"
        val line = store.add(text)
        val prosody = ProsodyAnalyzer.analyzeLine(text)
        assertEquals(prosody.syllableCount, line.syllableCount)
        assertEquals(prosody.stressPattern.joinToString(""), line.stressPattern)
        assertEquals(RhymePhonetics.rhymeKeys(RhymeConstraint.lineEndWord(text)).joinToString("|"), line.rhymeKeys)
        assertEquals("${prosody.syllableCount} syl · cold", line.prosodyBadge)

        val edited = store.updateText(line.id, "Coffee gone cold again tonight")!!
        assertEquals(ProsodyAnalyzer.analyzeLine(edited.text).syllableCount, edited.syllableCount)
        assertEquals(edited, store.all().single())
        assertTrue(edited.prosodyBadge.endsWith("· tonight"))
    }

    @Test
    fun trashUndoAndRestoreKeepOneCopy() = withStore {
        val line = store.add("Coffee gone cold")
        val trashed = store.trash(line.id, now = 5_000L)!!
        assertEquals(5_000L + TRASH_RETENTION_MILLIS, trashed.deleteAfter)
        assertTrue(store.all().isEmpty())
        assertEquals(listOf(line.id), store.trashed().map { it.line.id })

        assertEquals(line, store.restore(line.id))
        assertEquals(listOf(line), store.all())
        assertTrue(store.trashed().isEmpty())

        store.trash(line.id, now = 6_000L)
        store.restore(line.id)
        store.trash(line.id, now = 7_000L)
        assertEquals(1, store.trashed().size)
        assertNull(store.trash("missing"))
    }

    @Test
    fun purgeRemovesExpiredLinesAndTheirAudioOnly() = withStore {
        val voiced = store.add("Voiced", take = pendingTake(), audioDurationMs = 1_200L)
        val kept = store.add("Kept a while")
        val audio = store.audioFile(voiced.audioFileName!!)
        assertTrue(audio.exists())
        store.trash(voiced.id, now = 0L)
        store.trash(kept.id, now = 10_000L)

        assertTrue(store.purgeExpired(now = TRASH_RETENTION_MILLIS - 1).isEmpty())
        assertTrue(audio.exists())
        assertEquals(TRASH_RETENTION_MILLIS + 10_000L, store.nextExpiry(now = TRASH_RETENTION_MILLIS))

        assertEquals(listOf(voiced.id), store.purgeExpired(now = TRASH_RETENTION_MILLIS))
        assertFalse(audio.exists())
        assertEquals(listOf(kept.id), store.trashed().map { it.line.id })
    }

    @Test
    fun failedDeleteForeverPutsTheAudioBack() = withStore {
        val line = store.add("Voiced", take = pendingTake())
        val audio = store.audioFile(line.audioFileName!!)
        store.trash(line.id)
        store.beforeCommit = { throw IOException("disk full") }

        assertFailsWith<IOException> { store.permanentlyDelete(line.id) }
        assertTrue(audio.exists())
        assertEquals(1, store.trashed().size)
    }

    @Test
    fun failedSaveKeepsTheTakeWhereARetryFindsIt() = withStore {
        val take = pendingTake(bytes = "the only copy")
        store.beforeCommit = { throw IOException("disk full") }

        val failure = assertFailsWith<OneLinerSaveFailure> { store.add("Midnight rain", take = take, audioDurationMs = 900L) }
        assertEquals(take.canonicalPath, failure.takeNowAt!!.canonicalPath)
        assertEquals("the only copy", take.readText())
        assertTrue(store.all().isEmpty())

        // The move back fails too: the take stays adopted and a retry saves it from there.
        var moves = 0
        val move = store.moveFile
        store.moveFile = { from, to -> if (++moves == 2) throw IOException("busy") else move(from, to) }
        val stuck = assertFailsWith<OneLinerSaveFailure> { store.add("Midnight rain", take = take) }
        assertEquals(store.audioFile(take.name).canonicalPath, stuck.takeNowAt!!.canonicalPath)
        assertEquals("the only copy", stuck.takeNowAt!!.readText())

        store.beforeCommit = {}
        val saved = store.add("Midnight rain", take = stuck.takeNowAt, audioDurationMs = 900L)
        assertEquals(take.name, saved.audioFileName)
        assertEquals("the only copy", store.audioFile(take.name).readText())
        assertEquals(listOf(saved), store.all())
    }

    @Test
    fun sendToSongAppendsAndMarksUsedInOneWrite() = withStore {
        songs.saveProjects(listOf(SongProject(id = "song", title = "Tin Roof", lyrics = "first line", updatedAt = 1L)))
        val line = store.add("Coffee gone cold")

        val committed = store.sendToSong(line.id, "song", songs, now = 50L)!!
        val song = committed.single()
        assertEquals("first line\nCoffee gone cold", song.lyrics)
        assertEquals(50L, song.updatedAt)
        assertEquals("song", store.all().single().usedInProjectId)
        assertEquals(song, songs.projectsFlow.first().single())

        // The line stays in the pool and can go to the song again.
        store.sendToSong(line.id, "song", songs, now = 60L)
        assertEquals("first line\nCoffee gone cold\nCoffee gone cold", songs.projectsFlow.first().single().lyrics)
    }

    @Test
    fun sendToSongChangesNothingWhenEitherSideIsGone() = withStore {
        songs.saveProjects(listOf(SongProject(id = "song", lyrics = "first line")))
        val line = store.add("Coffee gone cold")

        assertNull(store.sendToSong(line.id, "deleted-song", songs))
        assertNull(store.all().single().usedInProjectId)

        // The marker cannot be written (the line went away): the song is left as it was.
        assertFailsWith<IllegalArgumentException> {
            songs.appendLineToProject("song", "orphan", 1L) { prefs -> store.markUsedIn(prefs, "gone", "song") }
        }
        assertEquals("first line", songs.projectsFlow.first().single().lyrics)

        val voiceOnly = store.add("", take = pendingTake())
        assertFailsWith<OneLinerHasNoWordsException> { store.sendToSong(voiceOnly.id, "song", songs) }
        assertEquals("first line", songs.projectsFlow.first().single().lyrics)
    }

    @Test
    fun restoreArrivingWhileThePurgeHoldsTheTakeAsideKeepsTheAudio() = withStore {
        val line = store.add("Voiced", take = pendingTake())
        val audio = store.audioFile(line.audioFileName!!)
        store.trash(line.id, now = 0L)
        val staged = CountDownLatch(1)
        val go = CountDownLatch(1)
        val move = store.moveFile
        // The purge stops right after setting the take aside, before it removes the row.
        store.moveFile = { from, to ->
            move(from, to)
            if (to.parentFile?.name == OneLinersStore.DELETING_FOLDER) { staged.countDown(); go.await() }
        }
        coroutineScope {
            val purge = async(Dispatchers.IO) { store.purgeExpired(now = TRASH_RETENTION_MILLIS) }
            withContext(Dispatchers.IO) { staged.await() }
            val restore = async(Dispatchers.IO) { store.restore(line.id) }
            // Give the restore every chance to land in the middle of the purge.
            withTimeoutOrNull(300) { restore.await() }
            go.countDown()
            purge.await()
            restore.await()
        }
        val live = store.all().any { it.id == line.id }
        if (live) assertTrue(audio.exists(), "the restored line lost its take")
        else assertTrue(store.trashed().none { it.line.id == line.id } && !audio.exists(), "a purged line left a row or its take")
    }

    @Test
    fun deleteForeverAfterARestoreKeepsTheLineAndItsAudio() = withStore {
        val line = store.add("Voiced", take = pendingTake())
        store.trash(line.id)
        store.restore(line.id)

        assertFalse(store.permanentlyDelete(line.id))
        assertTrue(store.purgeExpired(now = Long.MAX_VALUE).isEmpty())
        assertTrue(store.audioFile(line.audioFileName!!).exists())
        assertEquals(listOf(line.id), store.all().map { it.id })
    }

    @Test
    fun aSongAppendedInTheSameMillisecondAsItsDefaultKeepsItsTime() = withStore {
        songs.saveProjects(listOf(SongProject(id = "song", lyrics = "first", updatedAt = 1L)))
        val projectsKey = stringPreferencesKey("projects_json")
        // Encoding runs in the same millisecond as `now` far more often than not; each round must keep it.
        repeat(200) { round ->
            val now = System.currentTimeMillis()
            songs.appendLineToProject("song", "line $round", now)
            assertTrue(dataStore.data.first()[projectsKey]!!.contains("\"updatedAt\":$now"), "round $round dropped updatedAt")
            assertEquals(now, songs.projectsFlow.first().single().updatedAt)
        }
    }

    @Test
    fun concurrentChangesLeaveTheLatestPoolAsValidJson() = withStore {
        coroutineScope { (1..20).map { async(Dispatchers.IO) { store.add("Line $it", now = it.toLong()) } }.awaitAll() }
        // No republish: whatever change published last read the final pool.
        val snapshot = Json.decodeFromString<OneLinersSnapshot>(snapshotFile.readText())
        assertEquals(20, snapshot.count)
        assertEquals(listOf("Line 20", "Line 19", "Line 18"), snapshot.lines.map { it.text })
        assertTrue(snapshotFile.parentFile!!.listFiles()!!.none { it.name.endsWith(".tmp") })
    }

    @Test
    fun appendingLineStartsANewLine() {
        assertEquals("new", OneLinersStore.appendingLine("new", ""))
        assertEquals("old\nnew", OneLinersStore.appendingLine("new", "old"))
        assertEquals("old\nnew", OneLinersStore.appendingLine("new", "old\n"))
    }

    @Test
    fun reconcileClearsAbandonedTakesButNeverTheMainFolder() = withStore {
        val now = 100L * 24 * 60 * 60 * 1000
        val abandoned = pendingTake("old.wav").apply { setLastModified(now - OneLinersStore.ABANDONED_TAKE_AGE_MILLIS - 1) }
        val recent = pendingTake("recent.wav").apply { setLastModified(now - 1_000L) }
        val unnamed = store.audioFile("not-in-any-row.wav").apply { parentFile.mkdirs(); writeText("x"); setLastModified(0L) }

        store.reconcileAudioFiles(now)

        assertFalse(abandoned.exists())
        assertTrue(recent.exists())
        assertTrue(unnamed.exists())
    }

    @Test
    fun widgetSnapshotFollowsEveryChange() = withStore {
        repeat(4) {
            store.add("Line $it", now = it.toLong())
            assertEquals(it + 1, Json.decodeFromString<OneLinersSnapshot>(snapshotFile.readText()).count)
        }
        val snapshot = Json.decodeFromString<OneLinersSnapshot>(snapshotFile.readText())
        assertEquals(4, snapshot.count)
        assertEquals(listOf("Line 3", "Line 2", "Line 1"), snapshot.lines.map { it.text })
        assertEquals("ink", snapshot.appearance)

        store.trash(store.all().first().id)
        assertEquals(3, Json.decodeFromString<OneLinersSnapshot>(snapshotFile.readText()).count)
    }
}
