package com.rhymeai.app.data.sync

import kotlinx.coroutines.runBlocking
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URLDecoder
import java.util.Collections
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The real HTTP client against a local server standing in for Drive. */
class RealDriveClientTest {
    private class Request(val target: String, val body: String)

    private val socket = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
    private val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())
    private val base = "http://127.0.0.1:${socket.localPort}"

    /** Answers each request with [respond] (status, body) until the test ends. */
    private fun serve(respond: (Request) -> Pair<Int, String>) {
        thread(isDaemon = true) {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                client.use { connection ->
                    val reader = BufferedReader(InputStreamReader(connection.getInputStream(), Charsets.UTF_8))
                    val target = reader.readLine()?.split(' ')?.getOrNull(1) ?: return@use
                    var length = 0
                    while (true) {
                        val header = reader.readLine() ?: break
                        if (header.isEmpty()) break
                        if (header.startsWith("Content-Length:", ignoreCase = true)) length = header.substringAfter(':').trim().toInt()
                    }
                    val body = CharArray(length).also { var read = 0; while (read < length) read += reader.read(it, read, length - read) }
                    val request = Request(URLDecoder.decode(target, "UTF-8"), String(body))
                    requests += request
                    val (status, payload) = respond(request)
                    val bytes = payload.toByteArray()
                    connection.getOutputStream().apply {
                        write("HTTP/1.1 $status X\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(bytes)
                        flush()
                    }
                }
            }
        }
    }

    @AfterTest
    fun stop() = socket.close()

    @Test
    fun listingFollowsEveryPageAndKeepsAppProperties() = runBlocking {
        serve { request ->
            200 to if ("pageToken=" !in request.target) {
                """{"nextPageToken":"page-2","files":[{"id":"1","name":"rec_a_one.m4a","appProperties":{"sha256":"aa","bytes":"3"}}]}"""
            } else {
                """{"files":[{"id":"2","name":"rec_b_two.m4a","modifiedTime":"2026-10-22T21:00:00Z","version":"7"}]}"""
            }
        }

        val files = RealDriveClient("$base/drive", "$base/upload", "$base/revoke")
            .listFilesByNamePrefix("token", "rec_")

        assertEquals(listOf("rec_a_one.m4a", "rec_b_two.m4a"), files.map { it.name })
        assertEquals(mapOf("sha256" to "aa", "bytes" to "3"), files.first().appProperties)
        assertEquals("7", files.last().version)
        assertEquals(2, requests.size)
        assertTrue(requests.all { "spaces=appDataFolder" in it.target && "appProperties" in it.target })
        assertTrue("pageToken=page-2" in requests.last().target)
    }

    @Test
    fun revisionsFollowEveryPageAndDownloadByRevisionId() = runBlocking {
        serve { request ->
            200 to when {
                "alt=media" in request.target -> "manifest bytes"
                "pageToken=" !in request.target -> """{"nextPageToken":"p2","revisions":[{"id":"r1","modifiedTime":"2026-11-01T10:00:00Z","size":"9"}]}"""
                else -> """{"revisions":[{"id":"r2","modifiedTime":"2026-11-02T10:00:00Z"}]}"""
            }
        }
        val client = RealDriveClient("$base/drive", "$base/upload", "$base/revoke")

        assertEquals(
            listOf(DriveRevision("r1", "2026-11-01T10:00:00Z", 9L), DriveRevision("r2", "2026-11-02T10:00:00Z")),
            client.listRevisions("token", "file-1")
        )
        assertEquals("manifest bytes", String(client.downloadRevision("token", "file-1", "r2", 100L)))
        assertTrue(requests.take(2).all { it.target.startsWith("/drive/files/file-1/revisions?") })
        assertTrue("pageToken=p2" in requests[1].target)
        assertEquals("/drive/files/file-1/revisions/r2?alt=media", requests.last().target)
    }

    @Test
    fun aRefusedOrMissingRevisionSaysSoAndIsNotCalledAQuota() = runBlocking {
        var status = 403
        serve { status to """{"error":{"code":403,"message":"Only revisions marked keepForever can be downloaded."}}""" }
        val client = RealDriveClient("$base/drive", "$base/upload", "$base/revoke")

        val refused = runCatching { client.downloadRevision("token", "f", "r", 100L) }.exceptionOrNull()
        assertTrue(refused is DriveHttpException && refused.statusCode == 403)
        assertEquals("Google Drive refused: Opening the earlier backup failed (403): Only revisions marked keepForever can be downloaded.", refused.message)

        status = 404
        val gone = runCatching { client.downloadRevision("token", "f", "r", 100L) }.exceptionOrNull()
        assertEquals("This earlier backup is no longer in Google Drive.", gone?.message)
    }

    @Test
    fun revokePostsTheTokenAndReportsFailure() = runBlocking {
        var status = 200
        serve { status to "" }
        val client = RealDriveClient("$base/drive", "$base/upload", "$base/revoke")

        client.revokeToken("ya29.a+b")
        assertEquals("token=ya29.a%2Bb", requests.single().body)

        status = 400
        assertTrue(runCatching { client.revokeToken("expired") }.exceptionOrNull() is DriveHttpException)
    }
}
