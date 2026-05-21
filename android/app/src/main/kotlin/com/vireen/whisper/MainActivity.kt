package com.vireen.whisper

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File

class MainActivity : FlutterActivity() {
    private val pendingShareUris = mutableListOf<String>()
    private var quickShareChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        flutterEngine.plugins.add(DirPlugin())
        flutterEngine.plugins.add(BackgroundKeepAlivePlugin())
        flutterEngine.plugins.add(AudioSharePlugin())
        captureShareIntent(intent)
        quickShareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            QUICK_SHARE_CHANNEL
        )
        quickShareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumePendingShareUris" -> {
                    val uris = pendingShareUris.toList()
                    pendingShareUris.clear()
                    result.success(uris)
                }
                "stageSharedUris" -> {
                    val uris = call.argument<List<String>>("uris") ?: emptyList()
                    try {
                        result.success(stageSharedUris(uris))
                    } catch (error: Exception) {
                        result.error("stage_failed", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureShareIntent(intent)
        quickShareChannel?.invokeMethod("shareIntentReceived", null)
    }

    private fun captureShareIntent(sourceIntent: Intent?) {
        if (sourceIntent == null) {
            return
        }
        val uris = when (sourceIntent.action) {
            Intent.ACTION_SEND -> listOfNotNull(streamUri(sourceIntent))
            Intent.ACTION_SEND_MULTIPLE -> streamUris(sourceIntent)
            else -> emptyList()
        }
        if (uris.isEmpty()) {
            return
        }
        pendingShareUris.clear()
        pendingShareUris.addAll(uris.map { it.toString() })
    }

    @Suppress("DEPRECATION")
    private fun streamUri(sourceIntent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            sourceIntent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            sourceIntent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }
    }

    @Suppress("DEPRECATION")
    private fun streamUris(sourceIntent: Intent): List<Uri> {
        val values = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            sourceIntent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            sourceIntent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }
        return values?.filterNotNull() ?: emptyList()
    }

    private fun stageSharedUris(uriStrings: List<String>): List<String> {
        val targetDir = File(cacheDir, "quick_share").apply {
            mkdirs()
        }
        return uriStrings.mapIndexed { index, uriString ->
            val uri = Uri.parse(uriString)
            val displayName = displayNameFor(uri).ifBlank {
                "shared-${System.currentTimeMillis()}-$index"
            }
            val target = File(
                targetDir,
                "${System.currentTimeMillis()}-$index-${sanitizeFileName(displayName)}"
            )
            contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "Unable to open shared content: $uriString" }
                target.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            target.absolutePath
        }
    }

    private fun displayNameFor(uri: Uri): String {
        val projection = arrayOf(OpenableColumns.DISPLAY_NAME)
        contentResolver.query(uri, projection, null, null, null).use { cursor ->
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    return cursor.getString(index) ?: ""
                }
            }
        }
        return uri.lastPathSegment ?: ""
    }

    private fun sanitizeFileName(name: String): String {
        return name.replace(Regex("[\\\\/:*?\"<>|]"), "_").ifBlank {
            "shared-file"
        }
    }

    companion object {
        private const val QUICK_SHARE_CHANNEL = "com.vireen.whisper/android_quick_share"
    }
}
