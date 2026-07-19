package com.vireen.whisper

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.AtomicFile
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.LinkedHashMap
import java.util.LinkedHashSet
import java.util.UUID
import java.util.concurrent.Executors

class AndroidSystemSharePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sessionId = UUID.randomUUID().toString()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        // System shares are intentionally scoped to one app process. This task
        // is queued before Activity attachment captures a cold-start share.
        ioExecutor.execute { discardPreviousSessionState() }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        ioExecutor.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        captureShareIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean = captureShareIntent(intent)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_CONSUME_PENDING -> runIo(result) {
                loadEvents(pendingOnly = true)
                    .sortedBy { it.optLong("receivedAt") }
                    .map(::eventToMap)
            }
            METHOD_CONSUME_FAILURES -> runIo(result) { consumePendingFailures() }
            METHOD_UPDATE_PROGRESS -> {
                val eventId = call.argument<String>("eventId") ?: ""
                val peerId = call.argument<String>("peerId") ?: ""
                val publicKeyHash = call.argument<String>("publicKeyHash") ?: ""
                val textSent = call.argument<Boolean>("textSent") ?: false
                val waitingForConnection =
                    call.argument<Boolean>("waitingForConnection") ?: false
                val sentItemUris = call.argument<List<String>>("sentItemUris")
                    ?: emptyList()
                runIo(result) {
                    updateProgress(
                        eventId = eventId,
                        peerId = peerId,
                        publicKeyHash = publicKeyHash,
                        textSent = textSent,
                        waitingForConnection = waitingForConnection,
                        sentItemUris = sentItemUris
                    )
                }
            }
            METHOD_COMPLETE_PENDING -> {
                val eventId = call.argument<String>("eventId") ?: ""
                runIo(result) { completePendingEvent(eventId) }
            }
            METHOD_DISCARD_PENDING -> {
                val eventId = call.argument<String>("eventId") ?: ""
                runIo(result) { discardPendingEvent(eventId) }
            }
            METHOD_RELEASE_STAGED_ITEM -> {
                val uri = call.argument<String>("uri") ?: ""
                runIo(result) { releaseStagedItem(uri) }
            }
            else -> result.notImplemented()
        }
    }

    private fun runIo(result: MethodChannel.Result, operation: () -> Any?) {
        ioExecutor.execute {
            try {
                val value = operation()
                mainHandler.post { result.success(value) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("system_share_io", error.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun captureShareIntent(intent: Intent?): Boolean {
        if (intent == null || intent.getBooleanExtra(CONSUMED_EXTRA, false)) {
            return false
        }
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) {
            return false
        }

        // Configuration changes present the same Activity intent again.
        intent.putExtra(CONSUMED_EXTRA, true)
        val parsed = ShareIntentSnapshot.from(intent) ?: return false
        ioExecutor.execute {
            val rejectionCode = parsed.rejectionCode
                ?: stageShareEvent(parsed.snapshot!!)
            if (rejectionCode == null) {
                mainHandler.post { channel.invokeMethod(METHOD_SHARE_INTENT_RECEIVED, null) }
            } else {
                val receivedAt = System.currentTimeMillis()
                try {
                    recordShareFailure(rejectionCode, receivedAt)
                } catch (_: Exception) {
                    // The method-channel notification still lets a running UI explain rejection.
                }
                mainHandler.post {
                    channel.invokeMethod(
                        METHOD_SHARE_INTENT_REJECTED,
                        mapOf("code" to rejectionCode, "receivedAt" to receivedAt)
                    )
                }
            }
        }
        return true
    }

    private fun stageShareEvent(snapshot: ShareIntentSnapshot): String? {
        if (loadEvents(pendingOnly = true).size >= MAX_PENDING_EVENTS) {
            return FAILURE_QUEUE_FULL
        }
        if (snapshot.uris.size > MAX_ITEMS_PER_EVENT) {
            return FAILURE_TOO_MANY_ITEMS
        }
        if (snapshot.text.length > MAX_TEXT_LENGTH) {
            return FAILURE_TEXT_TOO_LARGE
        }
        val eventId = UUID.randomUUID().toString()
        val eventDirectory = File(stagingRoot(), eventId)
        if (!eventDirectory.mkdirs() && !eventDirectory.isDirectory) {
            return FAILURE_INVALID_CONTENT
        }

        val items = JSONArray()
        try {
            snapshot.uris.forEachIndexed { index, uri ->
                items.put(
                    stageItem(
                        eventDirectory = eventDirectory,
                        index = index,
                        sourceUri = uri,
                        fallbackMimeType = snapshot.mimeType
                    )
                )
            }
        } catch (rejection: ShareRejectionException) {
            eventDirectory.deleteRecursively()
            return rejection.code
        }
        val text = snapshot.text
        if (text.isEmpty() && items.length() == 0) {
            eventDirectory.deleteRecursively()
            return FAILURE_INVALID_CONTENT
        }

        val event = JSONObject()
            .put("schema", EVENT_SCHEMA_VERSION)
            .put("sessionId", sessionId)
            .put("id", eventId)
            .put("action", snapshot.action)
            .put("mimeType", snapshot.mimeType.take(MAX_MIME_TYPE_LENGTH))
            .put("text", text)
            .put("items", items)
            .put("receivedAt", System.currentTimeMillis())
            .put("pending", true)
            .put("targetPeerId", "")
            .put("targetPublicKeyHash", "")
            .put("textSent", false)
            .put("waitingForConnection", false)
            .put("sentItemUris", JSONArray())
        try {
            writeEvent(eventDirectory, event)
        } catch (_: Exception) {
            eventDirectory.deleteRecursively()
            return FAILURE_INVALID_CONTENT
        }
        return null
    }

    private fun stageItem(
        eventDirectory: File,
        index: Int,
        sourceUri: Uri,
        fallbackMimeType: String
    ): JSONObject {
        val metadata = sourceMetadata(sourceUri, fallbackMimeType)
        if (metadata.size != null && metadata.size > MAX_STAGED_ITEM_BYTES) {
            throw ShareRejectionException(FAILURE_ITEM_TOO_LARGE)
        }
        val suffix = safeExtension(metadata.displayName)
        val stagedFile = File(eventDirectory, "item-${index.toString().padStart(2, '0')}$suffix")
        val partialFile = File(eventDirectory, "${stagedFile.name}.part")
        var copied = 0L
        try {
            context.contentResolver.openInputStream(sourceUri).use { input ->
                if (input == null) {
                    throw ShareRejectionException(FAILURE_ITEM_UNAVAILABLE)
                }
                FileOutputStream(partialFile).use { output ->
                    val buffer = ByteArray(STREAM_BUFFER_SIZE)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) {
                            break
                        }
                        copied += read
                        if (copied > MAX_STAGED_ITEM_BYTES) {
                            throw ShareRejectionException(FAILURE_ITEM_TOO_LARGE)
                        }
                        output.write(buffer, 0, read)
                    }
                    output.fd.sync()
                }
            }
            if (!partialFile.renameTo(stagedFile)) {
                throw IllegalStateException("Unable to publish staged share item")
            }
        } catch (rejection: ShareRejectionException) {
            partialFile.delete()
            stagedFile.delete()
            throw rejection
        } catch (_: Exception) {
            partialFile.delete()
            stagedFile.delete()
            throw ShareRejectionException(FAILURE_ITEM_UNAVAILABLE)
        }

        val stagedUri = try {
            FileProvider.getUriForFile(
                context,
                "${context.packageName}.system_share_files",
                stagedFile
            )
        } catch (_: Exception) {
            stagedFile.delete()
            throw ShareRejectionException(FAILURE_ITEM_UNAVAILABLE)
        }
        return JSONObject()
            .put("uri", stagedUri.toString())
            .put("displayName", metadata.displayName.take(MAX_DISPLAY_NAME_LENGTH))
            .put("mimeType", metadata.mimeType.take(MAX_MIME_TYPE_LENGTH))
            .put("size", copied)
    }

    private fun sourceMetadata(uri: Uri, fallbackMimeType: String): SourceMetadata {
        var displayName = uri.lastPathSegment ?: "shared-item"
        var size: Long? = null
        try {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        displayName = cursor.getString(nameIndex)
                    }
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex).takeIf { it >= 0 }
                    }
                }
            }
        } catch (_: Exception) {
            // Providers may omit OpenableColumns; the streamed byte count is authoritative.
        }
        val mimeType = try {
            context.contentResolver.getType(uri) ?: fallbackMimeType
        } catch (_: Exception) {
            fallbackMimeType
        }
        return SourceMetadata(
            displayName = displayName.ifBlank { "shared-item" },
            mimeType = mimeType,
            size = size
        )
    }

    private fun updateProgress(
        eventId: String,
        peerId: String,
        publicKeyHash: String,
        textSent: Boolean,
        waitingForConnection: Boolean,
        sentItemUris: List<String>
    ): Boolean {
        val eventDirectory = eventDirectory(eventId) ?: return false
        val event = readEvent(eventDirectory) ?: return false
        if (!event.optBoolean("pending", true)) {
            return false
        }
        val normalizedPeerId = peerId.trim()
        val normalizedPublicKeyHash = publicKeyHash.trim()
        if (normalizedPeerId.length > MAX_PEER_ID_LENGTH ||
            ((normalizedPeerId.isEmpty()) != (normalizedPublicKeyHash.isEmpty())) ||
            (normalizedPublicKeyHash.isNotEmpty() &&
                !CANONICAL_PUBLIC_KEY_HASH.matches(normalizedPublicKeyHash))) {
            return false
        }
        val itemUris = event.optJSONArray("items").stringValues("uri").toSet()
        if (sentItemUris.size > MAX_ITEMS_PER_EVENT) {
            return false
        }
        val normalizedSentUris = LinkedHashSet<String>()
        sentItemUris.forEach { uri ->
            if (uri in itemUris) {
                normalizedSentUris.add(uri)
            }
        }
        event
            .put("targetPeerId", normalizedPeerId)
            .put("targetPublicKeyHash", normalizedPublicKeyHash)
            .put("textSent", textSent)
            .put("waitingForConnection", waitingForConnection)
            .put("sentItemUris", JSONArray(normalizedSentUris.toList()))
        writeEvent(eventDirectory, event)
        return true
    }

    private fun completePendingEvent(eventId: String): Boolean {
        val eventDirectory = eventDirectory(eventId) ?: return false
        val event = readEvent(eventDirectory) ?: return false
        if (!event.optBoolean("pending", true)) {
            return true
        }
        event
            .put("pending", false)
            .put("text", "")
            .put("targetPeerId", "")
            .put("targetPublicKeyHash", "")
            .put("sentItemUris", JSONArray())
        val items = event.optJSONArray("items") ?: JSONArray()
        if (items.length() == 0) {
            eventDirectory.deleteRecursively()
        } else {
            writeEvent(eventDirectory, event)
        }
        return true
    }

    private fun discardPendingEvent(eventId: String): Boolean {
        val eventDirectory = eventDirectory(eventId) ?: return false
        val event = readEvent(eventDirectory) ?: return false
        if (!event.optBoolean("pending", true)) {
            return false
        }
        return eventDirectory.deleteRecursively()
    }

    private fun releaseStagedItem(uriText: String): Boolean {
        val uri = Uri.parse(uriText)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT ||
            uri.authority != "${context.packageName}.system_share_files") {
            return false
        }
        for (eventDirectory in stagingRoot().listFiles().orEmpty()) {
            val event = readEvent(eventDirectory) ?: continue
            if (event.optBoolean("pending", true)) {
                continue
            }
            val items = event.optJSONArray("items") ?: JSONArray()
            val retained = JSONArray()
            var released = false
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index) ?: continue
                if (item.optString("uri") == uriText) {
                    stagedFileFor(item.optString("uri"))?.delete()
                    released = true
                } else {
                    retained.put(item)
                }
            }
            if (!released) {
                continue
            }
            if (retained.length() == 0) {
                eventDirectory.deleteRecursively()
            } else {
                event.put("items", retained)
                writeEvent(eventDirectory, event)
            }
            return true
        }
        return false
    }

    private fun stagedFileFor(uriText: String): File? {
        val uri = Uri.parse(uriText)
        val segments = uri.pathSegments
        if (segments.size != 3 || segments[0] != FILE_PROVIDER_ROOT) {
            return null
        }
        val eventDirectory = eventDirectory(segments[1]) ?: return null
        val candidate = File(eventDirectory, segments[2])
        return candidate.takeIf { it.parentFile?.canonicalFile == eventDirectory.canonicalFile }
    }

    private fun loadEvents(pendingOnly: Boolean): List<JSONObject> {
        val events = mutableListOf<JSONObject>()
        stagingRoot().listFiles().orEmpty().forEach { directory ->
            val event = readEvent(directory)
            if (event == null) {
                directory.deleteRecursively()
                return@forEach
            }
            if (!pendingOnly || event.optBoolean("pending", true)) {
                events.add(event)
            }
        }
        return events
    }

    private fun discardPreviousSessionState() {
        stagingRoot().listFiles().orEmpty().forEach { directory ->
            val event = readEvent(directory)
            if (event == null || event.optString("sessionId") != sessionId) {
                directory.deleteRecursively()
            }
        }
        AtomicFile(failureFile()).delete()
    }

    private fun eventToMap(event: JSONObject): Map<String, Any?> {
        val items = mutableListOf<Map<String, Any?>>()
        val itemArray = event.optJSONArray("items") ?: JSONArray()
        for (index in 0 until itemArray.length()) {
            val item = itemArray.optJSONObject(index) ?: continue
            items.add(
                mapOf(
                    "uri" to item.optString("uri"),
                    "displayName" to item.optString("displayName"),
                    "size" to item.optLong("size").takeIf { it >= 0 },
                    "mimeType" to item.optString("mimeType")
                )
            )
        }
        return mapOf(
            "id" to event.optString("id"),
            "action" to event.optString("action"),
            "mimeType" to event.optString("mimeType"),
            "text" to event.optString("text"),
            "items" to items,
            "receivedAt" to event.optLong("receivedAt"),
            "targetPeerId" to event.optString("targetPeerId"),
            "targetPublicKeyHash" to event.optString("targetPublicKeyHash"),
            "textSent" to event.optBoolean("textSent", false),
            "waitingForConnection" to event.optBoolean("waitingForConnection", false),
            "sentItemUris" to event.optJSONArray("sentItemUris").stringValues()
        )
    }

    private fun recordShareFailure(code: String, receivedAt: Long) {
        val failures = readPendingFailures().toMutableList()
        failures.add(
            JSONObject()
                .put("code", code)
                .put("receivedAt", receivedAt)
        )
        while (failures.size > MAX_PENDING_FAILURES) {
            failures.removeAt(0)
        }
        val atomicFile = AtomicFile(failureFile())
        val stream = atomicFile.startWrite()
        try {
            val values = JSONArray()
            failures.forEach(values::put)
            stream.write(values.toString().toByteArray(Charsets.UTF_8))
            atomicFile.finishWrite(stream)
        } catch (error: Exception) {
            atomicFile.failWrite(stream)
            throw error
        }
    }

    private fun consumePendingFailures(): List<Map<String, Any>> {
        val values = readPendingFailures().map { failure ->
            mapOf(
                "code" to failure.optString("code"),
                "receivedAt" to failure.optLong("receivedAt")
            )
        }
        AtomicFile(failureFile()).delete()
        return values
    }

    private fun readPendingFailures(): List<JSONObject> {
        val atomicFile = AtomicFile(failureFile())
        if (!atomicFile.baseFile.exists()) {
            return emptyList()
        }
        return try {
            val array = JSONArray(String(atomicFile.readFully(), Charsets.UTF_8))
            buildList {
                for (index in 0 until minOf(array.length(), MAX_PENDING_FAILURES)) {
                    array.optJSONObject(index)?.let(::add)
                }
            }
        } catch (_: Exception) {
            atomicFile.delete()
            emptyList()
        }
    }

    private fun failureFile(): File = File(context.filesDir, FAILURE_FILE_NAME)

    private fun writeEvent(eventDirectory: File, event: JSONObject) {
        val atomicFile = AtomicFile(File(eventDirectory, EVENT_FILE_NAME))
        val stream = atomicFile.startWrite()
        try {
            stream.write(event.toString().toByteArray(Charsets.UTF_8))
            atomicFile.finishWrite(stream)
        } catch (error: Exception) {
            atomicFile.failWrite(stream)
            throw error
        }
    }

    private fun readEvent(eventDirectory: File): JSONObject? {
        if (!eventDirectory.isDirectory) {
            return null
        }
        return try {
            val bytes = AtomicFile(File(eventDirectory, EVENT_FILE_NAME)).readFully()
            val event = JSONObject(String(bytes, Charsets.UTF_8))
            val items = event.optJSONArray("items") ?: JSONArray()
            val sentItemUris = event.optJSONArray("sentItemUris") ?: JSONArray()
            val targetPeerId = event.optString("targetPeerId")
            val targetPublicKeyHash = event.optString("targetPublicKeyHash")
            if (event.optInt("schema") != EVENT_SCHEMA_VERSION ||
                event.optString("id") != eventDirectory.name ||
                event.optString("text").length > MAX_TEXT_LENGTH ||
                items.length() > MAX_ITEMS_PER_EVENT ||
                sentItemUris.length() > MAX_ITEMS_PER_EVENT ||
                (targetPeerId.isEmpty() && targetPublicKeyHash.isNotEmpty()) ||
                (targetPublicKeyHash.isNotEmpty() &&
                    !CANONICAL_PUBLIC_KEY_HASH.matches(targetPublicKeyHash))) {
                null
            } else {
                event
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun stagingRoot(): File {
        val root = File(context.filesDir, FILE_PROVIDER_ROOT)
        if (!root.exists()) {
            root.mkdirs()
        }
        return root
    }

    private fun eventDirectory(eventId: String): File? {
        val canonicalId = try {
            UUID.fromString(eventId).toString()
        } catch (_: Exception) {
            return null
        }
        if (canonicalId != eventId.lowercase()) {
            return null
        }
        return File(stagingRoot(), canonicalId)
    }

    private fun safeExtension(displayName: String): String {
        val suffix = displayName.substringAfterLast('.', "")
        if (suffix.isEmpty() || suffix.length > MAX_EXTENSION_LENGTH ||
            suffix.any { !it.isLetterOrDigit() }) {
            return ""
        }
        return ".${suffix.lowercase()}"
    }

    private data class SourceMetadata(
        val displayName: String,
        val mimeType: String,
        val size: Long?
    )

    private data class ShareIntentSnapshot(
        val action: String,
        val mimeType: String,
        val text: String,
        val uris: List<Uri>
    ) {
        companion object {
            fun from(intent: Intent): ShareIntentParseResult? {
                val textParts = LinkedHashSet<String>()
                val uris = LinkedHashMap<String, Uri>()
                val acceptsSingleUri = intent.action == Intent.ACTION_SEND
                var textLength = 0
                var rejectionCode: String? = null

                fun addText(value: String) {
                    if (value.isEmpty() || value in textParts || rejectionCode != null) {
                        return
                    }
                    val nextLength = textLength +
                        (if (textParts.isEmpty()) 0 else 1) + value.length
                    if (nextLength > MAX_TEXT_LENGTH) {
                        rejectionCode = FAILURE_TEXT_TOO_LARGE
                        return
                    }
                    textParts.add(value)
                    textLength = nextLength
                }

                fun addUri(uri: Uri?) {
                    if (uri == null || rejectionCode != null) {
                        return
                    }
                    if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
                        rejectionCode = FAILURE_INVALID_CONTENT
                        return
                    }
                    val key = uri.toString()
                    // ACTION_SEND represents one shared item. Some Android
                    // providers expose that item through both EXTRA_STREAM and
                    // ClipData using different content URIs.
                    if (key !in uris && acceptsSingleUri && uris.isNotEmpty()) {
                        return
                    }
                    if (key !in uris && uris.size >= MAX_ITEMS_PER_EVENT) {
                        rejectionCode = FAILURE_TOO_MANY_ITEMS
                        return
                    }
                    uris.putIfAbsent(key, uri)
                }

                try {
                    intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
                        ?.let { addText(it.toString()) }
                } catch (_: Exception) {
                    rejectionCode = FAILURE_INVALID_CONTENT
                }
                try {
                    intent.getCharSequenceArrayListExtra(Intent.EXTRA_TEXT)
                        ?.forEach { addText(it.toString()) }
                } catch (_: Exception) {
                    rejectionCode = FAILURE_INVALID_CONTENT
                }
                streamUri(intent)?.let(::addUri)
                streamUris(intent).forEach(::addUri)
                intent.clipData?.let { clipData ->
                    for (index in 0 until clipData.itemCount) {
                        if (rejectionCode != null) {
                            break
                        }
                        val item = clipData.getItemAt(index)
                        item.text?.toString()?.let(::addText)
                        addUri(item.uri)
                    }
                }
                if (rejectionCode != null) {
                    return ShareIntentParseResult(rejectionCode = rejectionCode)
                }
                val text = textParts.joinToString("\n")
                if (text.isEmpty() && uris.isEmpty()) {
                    return null
                }
                return ShareIntentParseResult(
                    snapshot = ShareIntentSnapshot(
                        action = intent.action ?: "",
                        mimeType = intent.type ?: "",
                        text = text,
                        uris = uris.values.toList()
                    )
                )
            }

            @Suppress("DEPRECATION")
            private fun streamUri(intent: Intent): Uri? {
                return try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    } else {
                        intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
                    }
                } catch (_: Exception) {
                    null
                }
            }

            @Suppress("DEPRECATION")
            private fun streamUris(intent: Intent): List<Uri> {
                return try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                            ?: emptyList()
                    } else {
                        intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                            ?: emptyList()
                    }
                } catch (_: Exception) {
                    emptyList()
                }
            }
        }
    }

    private data class ShareIntentParseResult(
        val snapshot: ShareIntentSnapshot? = null,
        val rejectionCode: String? = null
    )

    private class ShareRejectionException(val code: String) : Exception()

    companion object {
        private const val CHANNEL_NAME = "com.vireen.whisper/android_system_share"
        private const val METHOD_CONSUME_PENDING = "consumePendingShares"
        private const val METHOD_CONSUME_FAILURES = "consumePendingShareFailures"
        private const val METHOD_SHARE_INTENT_RECEIVED = "shareIntentReceived"
        private const val METHOD_SHARE_INTENT_REJECTED = "shareIntentRejected"
        private const val METHOD_UPDATE_PROGRESS = "updatePendingShareProgress"
        private const val METHOD_COMPLETE_PENDING = "completePendingShare"
        private const val METHOD_DISCARD_PENDING = "discardPendingShare"
        private const val METHOD_RELEASE_STAGED_ITEM = "releaseStagedShareItem"
        private const val CONSUMED_EXTRA = "com.vireen.whisper.SYSTEM_SHARE_CONSUMED"
        private const val FILE_PROVIDER_ROOT = "android_system_shares"
        private const val EVENT_FILE_NAME = "event.json"
        private const val FAILURE_FILE_NAME = "android_system_share_failures.json"
        private const val EVENT_SCHEMA_VERSION = 2
        private const val MAX_PENDING_EVENTS = 16
        private const val MAX_PENDING_FAILURES = 16
        private const val MAX_ITEMS_PER_EVENT = 64
        private const val MAX_TEXT_LENGTH = 256 * 1024
        private const val MAX_DISPLAY_NAME_LENGTH = 1024
        private const val MAX_MIME_TYPE_LENGTH = 255
        private const val MAX_PEER_ID_LENGTH = 256
        private const val MAX_EXTENSION_LENGTH = 16
        private const val MAX_STAGED_ITEM_BYTES = 100L * 1024 * 1024 * 1024
        private const val STREAM_BUFFER_SIZE = 64 * 1024
        private const val FAILURE_QUEUE_FULL = "queue_full"
        private const val FAILURE_TOO_MANY_ITEMS = "too_many_items"
        private const val FAILURE_TEXT_TOO_LARGE = "text_too_large"
        private const val FAILURE_ITEM_TOO_LARGE = "item_too_large"
        private const val FAILURE_ITEM_UNAVAILABLE = "item_unavailable"
        private const val FAILURE_INVALID_CONTENT = "invalid_content"
        private val CANONICAL_PUBLIC_KEY_HASH = Regex("^[A-Za-z0-9_-]{43}$")
    }
}

private fun JSONArray?.stringValues(key: String? = null): List<String> {
    if (this == null) {
        return emptyList()
    }
    val values = mutableListOf<String>()
    for (index in 0 until length()) {
        val value = if (key == null) {
            optString(index)
        } else {
            optJSONObject(index)?.optString(key) ?: ""
        }
        if (value.isNotEmpty()) {
            values.add(value)
        }
    }
    return values
}
