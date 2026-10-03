package com.rhymeai.app.service

import java.util.Collections
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.coroutines.CoroutineContext

class LocalModelOperationGateTest {
    @Test
    fun reselectWaitsForCancelledNativeLoadAndRejectsItsStaleResult() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val gate = LocalModelOperationGate()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val secondFinished = CompletableDeferred<Unit>()
        val published = Collections.synchronizedList(mutableListOf<String>())

        try {
            gate.launch(scope, gate.begin(),
                operation = {
                    firstStarted.complete(Unit)
                    withContext(NonCancellable) { releaseFirst.await() }
                },
                onSuccess = { published += "old model" },
                onFailure = { published += "old error" },
                onFinished = { published += "old finished" }
            )
            withTimeout(2_000) { firstStarted.await() }
            gate.launch(scope, gate.begin(),
                operation = { published += "load new model" },
                onSuccess = { published += "new model" },
                onFailure = { published += "new error" },
                onFinished = { secondFinished.complete(Unit) }
            )
            assertEquals(emptyList(), published.toList())
            releaseFirst.complete(Unit)
            withTimeout(2_000) { secondFinished.await() }
            assertEquals(listOf("load new model", "new model"), published.toList())
        } finally {
            releaseFirst.complete(Unit)
            scope.cancel()
        }
    }

    @Test
    fun unloadSupersedesPendingLoadBeforePublishingReadyState() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val gate = LocalModelOperationGate()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val unloaded = CompletableDeferred<Unit>()
        val published = Collections.synchronizedList(mutableListOf<String>())

        try {
            gate.launch(scope, gate.begin(),
                operation = {
                    firstStarted.complete(Unit)
                    withContext(NonCancellable) { releaseFirst.await() }
                },
                onSuccess = { published += "ready" },
                onFailure = { published += "error" },
                onFinished = { published += "load finished" }
            )
            withTimeout(2_000) { firstStarted.await() }
            gate.launch(scope, gate.begin(),
                operation = { published += "native unload" },
                onSuccess = { unloaded.complete(Unit) },
                onFailure = { published += "unload error" },
                onFinished = {}
            )
            assertEquals(emptyList(), published.toList())
            releaseFirst.complete(Unit)
            withTimeout(2_000) { unloaded.await() }
            assertEquals(listOf("native unload"), published.toList())
        } finally {
            releaseFirst.complete(Unit)
            scope.cancel()
        }
    }

    @Test
    fun failedCancelledLoadCannotReplaceNewSelectionWithStaleError() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val gate = LocalModelOperationGate()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val secondFinished = CompletableDeferred<Unit>()
        val published = Collections.synchronizedList(mutableListOf<String>())

        try {
            gate.launch(scope, gate.begin(),
                operation = {
                    firstStarted.complete(Unit)
                    withContext(NonCancellable) { releaseFirst.await() }
                    throw IllegalStateException("old load failed")
                },
                onSuccess = { published += "old ready" },
                onFailure = { published += it.message.orEmpty() },
                onFinished = { published += "old finished" }
            )
            withTimeout(2_000) { firstStarted.await() }
            gate.launch(scope, gate.begin(),
                operation = { published += "load new model" },
                onSuccess = { published += "new ready" },
                onFailure = { published += it.message.orEmpty() },
                onFinished = { secondFinished.complete(Unit) }
            )
            releaseFirst.complete(Unit)
            withTimeout(2_000) { secondFinished.await() }
            assertEquals(listOf("load new model", "new ready"), published.toList())
        } finally {
            releaseFirst.complete(Unit)
            scope.cancel()
        }
    }

    @Test
    fun thirdLoadWaitsForFirstLoadCleanupAfterMiddleWaiterIsCancelled() = runBlocking {
        assertThirdOperationWaitsForFirstCleanup("load C")
    }

    @Test
    fun thirdUnloadWaitsForFirstLoadCleanupAfterMiddleWaiterIsCancelled() = runBlocking {
        assertThirdOperationWaitsForFirstCleanup("unload C")
    }

    @Test
    fun thirdLoadWaitsForFirstCleanupWhenMiddleJobNeverStarts() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val queued = QueuedDispatcher()
        val middleScope = CoroutineScope(SupervisorJob() + queued)
        val gate = LocalModelOperationGate()
        val releaseFirst = CompletableDeferred<Unit>()
        val cleanupStarted = CompletableDeferred<Unit>()
        val releaseCleanup = CompletableDeferred<Unit>()
        val thirdEntered = CompletableDeferred<Unit>()
        var middleRan = false

        try {
            gate.launch(scope, gate.begin(),
                operation = {
                    withContext(NonCancellable) {
                        releaseFirst.await()
                        cleanupStarted.complete(Unit)
                        releaseCleanup.await()
                    }
                },
                onSuccess = {}, onFailure = {}, onFinished = {}
            )
            gate.launch(middleScope, gate.begin(),
                operation = { middleRan = true },
                onSuccess = {}, onFailure = {}, onFinished = {}
            )
            gate.launch(scope, gate.begin(),
                operation = { thirdEntered.complete(Unit) },
                onSuccess = {}, onFailure = {}, onFinished = {}
            )
            assertFalse(thirdEntered.isCompleted)
            releaseFirst.complete(Unit)
            withTimeout(2_000) { cleanupStarted.await() }
            assertFalse(thirdEntered.isCompleted)
            releaseCleanup.complete(Unit)
            withTimeout(2_000) { thirdEntered.await() }
            queued.runAll()
            assertFalse(middleRan)
        } finally {
            releaseFirst.complete(Unit)
            releaseCleanup.complete(Unit)
            middleScope.cancel()
            scope.cancel()
        }
    }

    private suspend fun assertThirdOperationWaitsForFirstCleanup(finalOperation: String) {
        // Unconfined launch reaches the mutex before returning, so B is waiting when C cancels it.
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val gate = LocalModelOperationGate()
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val cleanupStarted = CompletableDeferred<Unit>()
        val releaseCleanup = CompletableDeferred<Unit>()
        val thirdEntered = CompletableDeferred<Unit>()
        val published = mutableListOf<String>()

        try {
            gate.launch(scope, gate.begin(),
                operation = {
                    firstStarted.complete(Unit)
                    withContext(NonCancellable) {
                        releaseFirst.await()
                        cleanupStarted.complete(Unit)
                        releaseCleanup.await()
                    }
                },
                onSuccess = { published += "old ready" },
                onFailure = { published += "old error" },
                onFinished = { published += "old finished" }
            )
            withTimeout(2_000) { firstStarted.await() }
            gate.launch(scope, gate.begin(),
                operation = { published += "middle load" },
                onSuccess = { published += "middle ready" },
                onFailure = { published += "middle error" },
                onFinished = { published += "middle finished" }
            )
            gate.launch(scope, gate.begin(),
                operation = {
                    published += finalOperation
                    thirdEntered.complete(Unit)
                },
                onSuccess = { published += "third ready" },
                onFailure = { published += "third error" },
                onFinished = {}
            )
            assertFalse(thirdEntered.isCompleted)
            releaseFirst.complete(Unit)
            withTimeout(2_000) { cleanupStarted.await() }
            assertFalse(thirdEntered.isCompleted)
            releaseCleanup.complete(Unit)
            withTimeout(2_000) { thirdEntered.await() }
            assertEquals(listOf(finalOperation, "third ready"), published)
        } finally {
            releaseFirst.complete(Unit)
            releaseCleanup.complete(Unit)
            scope.cancel()
        }
    }

    private class QueuedDispatcher : CoroutineDispatcher() {
        private val queue = ArrayDeque<Runnable>()

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            queue.addLast(block)
        }

        fun runAll() {
            while (queue.isNotEmpty()) queue.removeFirst().run()
        }
    }
}
