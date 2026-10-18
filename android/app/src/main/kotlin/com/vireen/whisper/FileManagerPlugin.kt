package com.vireen.whisper

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ThumbnailUtils
import android.os.Build
import android.util.Size
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * Thumbnails for the remote file manager (another device browsing this
 * phone's files). Android has no trash: deletions are confirmed in the UI
 * and done in Dart.
 */
class FileManagerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: android.content.Context? = null
    private val worker = Executors.newFixedThreadPool(2)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.vireen.whisper/file_manager")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "thumbnail" -> {
                val path = call.argument<String>("path").orEmpty()
                val size = call.argument<Int>("size") ?: 256
                val video = call.argument<Boolean>("video") ?: false
                worker.execute {
                    val bytes = try {
                        thumbnail(File(path), size, video)
                    } catch (_: Exception) {
                        null
                    }
                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(bytes) }
                }
            }
            "trash" -> result.success(false)
            "scan" -> {
                val paths = call.argument<List<String>>("paths").orEmpty()
                if (paths.isNotEmpty() && context != null) {
                    android.media.MediaScannerConnection.scanFile(context, paths.toTypedArray(), null, null)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun thumbnail(file: File, size: Int, video: Boolean): ByteArray? {
        if (!file.isFile) {
            return null
        }
        val bitmap: Bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (video) {
                ThumbnailUtils.createVideoThumbnail(file, Size(size, size), null)
            } else {
                ThumbnailUtils.createImageThumbnail(file, Size(size, size), null)
            }
        } else {
            if (video) {
                return null
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= size && bounds.outHeight / (sample * 2) >= size) {
                sample *= 2
            }
            BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
        bitmap.recycle()
        return out.toByteArray()
    }
}
