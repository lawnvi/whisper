package com.vireen.whisper

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class AndroidDocumentPickerPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(
            binding.binaryMessenger,
            "com.vireen.whisper/android_document_picker"
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        ioExecutor.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
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
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFiles" -> pickFiles(call, result)
            "readBytes" -> readBytes(call, result)
            "metadata" -> metadata(call, result)
            else -> result.notImplemented()
        }
    }

    private fun pickFiles(call: MethodCall, result: MethodChannel.Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("no_activity", "Android document picker needs an activity", null)
            return
        }
        if (pendingPickResult != null) {
            result.error("picker_busy", "A document picker is already open", null)
            return
        }
        val allowMultiple = call.argument<Boolean>("allowMultiple") ?: true
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            currentActivity.startActivityForResult(intent, PICK_FILES_REQUEST_CODE)
        } catch (error: Exception) {
            pendingPickResult = null
            result.error("picker_failed", error.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_FILES_REQUEST_CODE) {
            return false
        }
        val result = pendingPickResult ?: return true
        pendingPickResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Map<String, Any?>>())
            return true
        }

        val uris = mutableListOf<Uri>()
        val clipData = data.clipData
        if (clipData != null) {
            for (index in 0 until clipData.itemCount) {
                clipData.getItemAt(index).uri?.let { uris.add(it) }
            }
        } else {
            data.data?.let { uris.add(it) }
        }

        val flags = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
        val items = uris.map { uri ->
            try {
                context.contentResolver.takePersistableUriPermission(uri, flags)
            } catch (_: Exception) {
                // Some providers grant only transient access. Transfer still works
                // while the app process keeps the permission.
            }
            metadataFor(uri)
        }
        result.success(items)
        return true
    }

    private fun readBytes(call: MethodCall, result: MethodChannel.Result) {
        val uriText = call.argument<String>("uri") ?: ""
        val offset = call.argument<Number>("offset")?.toLong() ?: 0L
        val length = call.argument<Number>("length")?.toInt() ?: 0
        if (uriText.isBlank()) {
            result.error("invalid_uri", "Document uri is empty", null)
            return
        }
        if (offset < 0 || length < 0) {
            result.error("invalid_range", "Document read range is invalid", null)
            return
        }
        ioExecutor.execute {
            try {
                val bytes = readDocumentRange(Uri.parse(uriText), offset, length)
                mainHandler.post { result.success(bytes) }
            } catch (error: Exception) {
                mainHandler.post { result.error("read_failed", error.message, null) }
            }
        }
    }

    private fun metadata(call: MethodCall, result: MethodChannel.Result) {
        val uriText = call.argument<String>("uri") ?: ""
        if (uriText.isBlank()) {
            result.success(null)
            return
        }
        ioExecutor.execute {
            try {
                val item = metadataFor(Uri.parse(uriText))
                mainHandler.post { result.success(item) }
            } catch (_: Exception) {
                mainHandler.post { result.success(null) }
            }
        }
    }

    private fun readDocumentRange(uri: Uri, offset: Long, length: Int): ByteArray {
        if (length == 0) {
            return ByteArray(0)
        }
        context.contentResolver.openInputStream(uri).use { input ->
            if (input == null) {
                throw IllegalStateException("Unable to open document stream")
            }
            var remainingOffset = offset
            while (remainingOffset > 0) {
                val skipped = input.skip(remainingOffset)
                if (skipped > 0) {
                    remainingOffset -= skipped
                    continue
                }
                if (input.read() == -1) {
                    return ByteArray(0)
                }
                remainingOffset -= 1
            }

            val output = ByteArrayOutputStream(length)
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var remaining = length
            while (remaining > 0) {
                val read = input.read(buffer, 0, minOf(buffer.size, remaining))
                if (read == -1) {
                    break
                }
                output.write(buffer, 0, read)
                remaining -= read
            }
            return output.toByteArray()
        }
    }

    private fun metadataFor(uri: Uri): Map<String, Any?> {
        var name = uri.lastPathSegment ?: "document"
        var size = 0L
        var lastModified = 0L
        try {
            context.contentResolver.query(
                uri,
                arrayOf(
                    OpenableColumns.DISPLAY_NAME,
                    OpenableColumns.SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED
                ),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    val modifiedIndex =
                        cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        name = cursor.getString(nameIndex)
                    }
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex)
                    }
                    if (modifiedIndex >= 0 && !cursor.isNull(modifiedIndex)) {
                        lastModified = cursor.getLong(modifiedIndex)
                    }
                }
            }
        } catch (_: Exception) {
            // Fall back to the URI segment; not every document provider exposes
            // all OpenableColumns.
        }
        val mimeType = try {
            context.contentResolver.getType(uri) ?: ""
        } catch (_: Exception) {
            ""
        }
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "size" to size,
            "mimeType" to mimeType,
            "lastModified" to lastModified
        )
    }

    companion object {
        private const val PICK_FILES_REQUEST_CODE = 49318
        private const val DEFAULT_BUFFER_SIZE = 64 * 1024
    }
}
