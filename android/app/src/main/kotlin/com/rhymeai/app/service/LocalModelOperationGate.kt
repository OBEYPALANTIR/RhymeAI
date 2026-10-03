package com.rhymeai.app.service

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Keeps native load/unload operations in selection order, even when a native call ignores cancellation. */
internal class LocalModelOperationGate {
    private val operationMutex = Mutex()
    private var revision = 0L
    private var operation: Job? = null

    internal data class Ticket(val revision: Long)

    fun begin(): Ticket {
        revision++
        operation?.cancel()
        return Ticket(revision)
    }

    fun isCurrent(ticket: Ticket): Boolean = ticket.revision == revision

    fun launch(
        scope: CoroutineScope,
        ticket: Ticket,
        operation: suspend () -> Unit,
        onSuccess: () -> Unit,
        onFailure: (Exception) -> Unit,
        onFinished: () -> Unit
    ) {
        this.operation = scope.launch {
            operationMutex.withLock {
                if (!isCurrent(ticket)) return@withLock
                try {
                    operation()
                    if (isCurrent(ticket)) onSuccess()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    if (isCurrent(ticket)) onFailure(error)
                } finally {
                    if (isCurrent(ticket)) onFinished()
                }
            }
        }
    }
}
