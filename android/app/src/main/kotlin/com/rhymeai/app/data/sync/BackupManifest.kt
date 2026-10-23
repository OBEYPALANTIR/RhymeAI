package com.rhymeai.app.data.sync

import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.time.Instant

/** The manifest failed its hash, shape or identity checks; nothing from it may be merged. */
class DamagedBackupException(cause: Throwable? = null) :
    Exception(BackupManifest.DAMAGED_MESSAGE, cause)

/** The manifest was written by a newer app; reading it could drop fields it relies on. */
class UnsupportedBackupVersionException(val version: Int) :
    Exception("This backup was made by a newer version of Writers Block. Update the app to use it.")

/**
 * Backup manifest v4: plain UTF-8 JSON, identical on Android and iOS and pinned by
 * `shared/fixtures/sync-manifest-v4.json`. `manifestSha256` covers the canonical
 * form of the object without that key: keys sorted by code point, no whitespace,
 * only `\"`, `\\`, `\n`, `\r`, `\t` and lowercase `\u00xx` escapes, integers only.
 * Every precedence time (`updatedAt`, `trashedAt`, `uploadedAt`, `deletedAt`) is an
 * integer of epoch milliseconds; `savedAt` is ISO-8601 UTC with milliseconds.
 */
object BackupManifest {
    const val VERSION = 4
    const val FILE_NAME = "rhymeai-manifest.json"
    const val MIME_TYPE = "application/json"
    const val RECORDING_PREFIX = "rec_"
    const val RECORDING_MIME_TYPE = "application/octet-stream"
    const val PLATFORM = "android"
    const val HASH_KEY = "manifestSha256"
    const val PRECEDENCE_REPAIRED = "precedenceRepaired"
    const val TRASHED_AT_REPAIRED = "trashedAtRepaired"
    const val DAMAGED_MESSAGE = "Backup file is damaged; it was not merged."

    private val sha256Pattern = Regex("[0-9a-f]{64}")
    private val integerPattern = Regex("-?(0|[1-9][0-9]*)")

    /** Drive name of a raw recording; never collides with the RAI1 `.enc` names. */
    fun recordingDriveName(recordingId: String): String = "$RECORDING_PREFIX$recordingId"

    fun encode(blob: SyncBlob, savedAtMillis: Long, clientId: String): ByteArray {
        blob.validate()
        val body = buildJsonObject {
            put("version", VERSION)
            put("savedAt", isoMillis(savedAtMillis))
            put("savedByClientId", clientId)
            put("platform", PLATFORM)
            putJsonArray("projects") { blob.projects.forEach { add(projectJson(it)) } }
            putJsonArray("trashed") {
                blob.trashed.forEach { entry ->
                    val fields = projectJson(entry.project) + ("trashedAt" to JsonPrimitive(entry.deletedAt))
                    add(JsonObject(if (entry.deletedAtRepaired) fields + (TRASHED_AT_REPAIRED to JsonPrimitive(true)) else fields))
                }
            }
            putJsonArray("recordings") {
                blob.recordings.forEach { entry ->
                    addJsonObject {
                        put("id", entry.id)
                        put("projectId", entry.projectId)
                        put("fileName", entry.fileName)
                        put("bytes", entry.sizeBytes)
                        put("sha256", entry.sha256)
                        put("uploadedAt", entry.uploadedAt)
                        if (entry.precedenceRepaired) put(PRECEDENCE_REPAIRED, true)
                    }
                }
            }
            putJsonArray("deletions") {
                blob.deletions.forEach { deletion ->
                    addJsonObject {
                        put("projectId", deletion.projectId)
                        put("fileName", deletion.fileName?.let(::JsonPrimitive) ?: JsonNull)
                        deletion.recordingId?.let { put("recordingId", it) }
                        if (deletion.timeKnown) put("deletedAt", deletion.deletedAt)
                    }
                }
            }
        }
        val hash = sha256Hex(canonical(body).toByteArray(Charsets.UTF_8))
        return canonical(JsonObject(body + (HASH_KEY to JsonPrimitive(hash)))).toByteArray(Charsets.UTF_8)
    }

    /** Throws [DamagedBackupException] or [UnsupportedBackupVersionException]; never returns partial data. */
    fun decode(bytes: ByteArray): SyncBlob {
        val root = try {
            val text = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
            Json.parseToJsonElement(text).jsonObject
        } catch (e: Exception) {
            throw DamagedBackupException(e)
        }
        val version = (root["version"] as? JsonPrimitive)?.takeUnless { it.isString }?.content?.toIntOrNull()
            ?: throw DamagedBackupException()
        if (version > VERSION) throw UnsupportedBackupVersionException(version)
        if (version != VERSION) throw DamagedBackupException()
        val expected = (root[HASH_KEY] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: throw DamagedBackupException()
        return try {
            val actual = sha256Hex(canonical(JsonObject(root - HASH_KEY)).toByteArray(Charsets.UTF_8))
            if (actual != expected) throw DamagedBackupException()
            SyncBlob(
                projects = root.array("projects").map { projectFrom(it.jsonObject) },
                trashed = root.array("trashed").map { element ->
                    val fields = element.jsonObject
                    TrashedSongProject(projectFrom(fields), deletedAt = fields.timeOrUnknown("trashedAt"), deletedAtRepaired = fields.flag(TRASHED_AT_REPAIRED))
                },
                recordings = root.array("recordings").map { element ->
                    val fields = element.jsonObject
                    val sha = fields.string("sha256")
                    require(sha256Pattern.matches(sha)) { "Invalid recording hash" }
                    RecordingManifestEntry(
                        projectId = fields.string("projectId"),
                        fileName = fields.string("fileName"),
                        sizeBytes = fields.long("bytes"),
                        modifiedAt = 0L,
                        sha256 = sha,
                        // A32: an absent time is unknown (0) and gets its first-seen time before any merge.
                        uploadedAt = fields.timeOrUnknown("uploadedAt"),
                        // An early v4 manifest has no recording id: the A21 derived id of its song, name and bytes.
                        id = if (fields.containsKey("id")) fields.string("id")
                        else RecordingManifestEntry.legacyRecordingId(fields.string("projectId"), fields.string("fileName"), sha),
                        precedenceRepaired = fields.flag(PRECEDENCE_REPAIRED)
                    )
                },
                deletions = root.array("deletions").map { element ->
                    val fields = element.jsonObject
                    val fileName = fields["fileName"] ?: throw IllegalArgumentException("Missing fileName")
                    SyncDeletion(
                        projectId = fields.string("projectId"),
                        // An id tombstone may carry an empty file name; it is never a song tombstone.
                        fileName = if (fileName is JsonNull) null else fileName.jsonPrimitive.also {
                            require(it.isString) { "Invalid fileName" }
                        }.content.takeUnless { it.isEmpty() && fields["recordingId"].let { r -> r != null && r !is JsonNull } },
                        deletedAt = fields.timeOrUnknown("deletedAt"),
                        recordingId = fields["recordingId"]?.takeUnless { it is JsonNull }?.jsonPrimitive
                            ?.also { require(it.isString) { "Invalid recordingId" } }?.content
                    )
                },
                savedAt = Instant.parse(root.string("savedAt")).toEpochMilli(),
                savedByClientId = root.string("savedByClientId")
            ).also(SyncBlob::validate)
        } catch (e: DamagedBackupException) {
            throw e
        } catch (e: Exception) {
            throw DamagedBackupException(e)
        }
    }

    /** The `manifestSha256` a manifest carries, after checking it against its canonical form. */
    fun hashOf(bytes: ByteArray): String {
        decode(bytes)
        return Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject.getValue(HASH_KEY).jsonPrimitive.content
    }

    fun canonical(element: JsonElement): String = StringBuilder().also { writeCanonical(element, it) }.toString()

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private val isoMillisFormat = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
        .withZone(java.time.ZoneOffset.UTC)

    /** `savedAt`: ISO-8601 UTC, always with milliseconds. */
    fun isoMillis(millis: Long): String = isoMillisFormat.format(Instant.ofEpochMilli(millis))

    private fun projectJson(project: SongProject): JsonObject = buildJsonObject {
        put("id", project.id)
        put("title", project.title)
        put("lyrics", project.lyrics)
        put("theme", project.theme)
        put("updatedAt", project.updatedAt)
        if (project.precedenceRepaired) put(PRECEDENCE_REPAIRED, true)
    }

    private fun projectFrom(fields: JsonObject) = SongProject(
        id = fields.string("id"),
        title = fields.string("title"),
        lyrics = fields.string("lyrics"),
        theme = fields.string("theme"),
        updatedAt = fields.timeOrUnknown("updatedAt"),
        precedenceRepaired = fields.flag(PRECEDENCE_REPAIRED)
    )

    /**
     * A37: `precedenceRepaired: true` on a song or recording (`trashedAtRepaired: true` for a
     * Trash entry's time) marks a first-seen repair; written only when true, so a manifest
     * without repairs is byte-identical to one written before the flags existed.
     */
    private fun JsonObject.flag(key: String): Boolean = when (val value = this[key]) {
        null -> false
        else -> value.jsonPrimitive.also { require(!it.isString && it.content in setOf("true", "false")) { "$key must be a boolean" } }.content == "true"
    }

    private fun JsonObject.array(key: String): JsonArray = getValue(key).jsonArray

    private fun JsonObject.string(key: String): String =
        getValue(key).jsonPrimitive.also { require(it.isString) { "$key must be a string" } }.content

    private fun JsonObject.long(key: String): Long =
        getValue(key).jsonPrimitive.also { require(!it.isString) { "$key must be a number" } }.long

    /** A32/A38: an absent precedence time is unknown (0) and is repaired before any merge; a wrong type is refused. */
    private fun JsonObject.timeOrUnknown(key: String): Long = if (containsKey(key)) long(key) else 0L

    private fun writeCanonical(element: JsonElement, out: StringBuilder) {
        when (element) {
            is JsonObject -> {
                out.append('{')
                element.keys.sortedWith(codePointOrder).forEachIndexed { index, key ->
                    if (index > 0) out.append(',')
                    writeString(key, out)
                    out.append(':')
                    writeCanonical(element.getValue(key), out)
                }
                out.append('}')
            }
            is JsonArray -> {
                out.append('[')
                element.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    writeCanonical(item, out)
                }
                out.append(']')
            }
            JsonNull -> out.append("null")
            is JsonPrimitive -> when {
                element.isString -> writeString(element.content, out)
                element.content == "true" || element.content == "false" -> out.append(element.content)
                integerPattern.matches(element.content) -> out.append(element.content)
                else -> throw IllegalArgumentException("Manifest numbers must be integers")
            }
        }
    }

    private fun writeString(value: String, out: StringBuilder) {
        out.append('"')
        for (ch in value) {
            when {
                ch == '"' -> out.append("\\\"")
                ch == '\\' -> out.append("\\\\")
                ch == '\n' -> out.append("\\n")
                ch == '\r' -> out.append("\\r")
                ch == '\t' -> out.append("\\t")
                ch < ' ' -> out.append("\\u%04x".format(ch.code))
                else -> out.append(ch)
            }
        }
        out.append('"')
    }

    private val codePointOrder = Comparator<String> { a, b ->
        var i = 0
        var j = 0
        while (i < a.length && j < b.length) {
            val ca = a.codePointAt(i)
            val cb = b.codePointAt(j)
            if (ca != cb) return@Comparator ca.compareTo(cb)
            i += Character.charCount(ca)
            j += Character.charCount(cb)
        }
        (a.length - i).compareTo(b.length - j)
    }
}
