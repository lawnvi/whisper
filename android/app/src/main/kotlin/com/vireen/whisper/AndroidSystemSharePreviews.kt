package com.vireen.whisper

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.AtomicFile
import java.io.File

/**
 * Shared photos and videos are copied into the app before they are sent, and
 * the copy is deleted once the transfer ends. The chat still points at that
 * copy, so a small preview is kept in its place; the oldest previews go first
 * once they outgrow [MAX_TOTAL_BYTES].
 */
internal object AndroidSystemSharePreviews {
    private const val ROOT = "android_system_share_previews"
    private const val STAGED_ROOT = "android_system_shares"
    private const val PREVIEW_EDGE = 1200
    private const val JPEG_QUALITY = 85
    private const val MAX_TOTAL_BYTES = 96L * 1024 * 1024
    private val SAFE_SEGMENT = Regex("^[A-Za-z0-9._-]{1,128}$")

    /** Saves a preview of a staged item; call before its copy is deleted. */
    fun retain(context: Context, uri: Uri, mimeType: String) {
        if (!mimeType.startsWith("image/") && !mimeType.startsWith("video/")) {
            return
        }
        val target = previewFile(context, uri) ?: return
        val bitmap = try {
            MediaThumbnails.create(context, uri, PREVIEW_EDGE, PREVIEW_EDGE)
        } catch (_: Exception) {
            null
        } ?: return
        try {
            target.parentFile?.mkdirs()
            val atomicFile = AtomicFile(target)
            val output = atomicFile.startWrite()
            try {
                // Keep transparency for screenshots and stickers.
                val format = if (bitmap.hasAlpha()) {
                    Bitmap.CompressFormat.PNG
                } else {
                    Bitmap.CompressFormat.JPEG
                }
                bitmap.compress(format, JPEG_QUALITY, output)
                atomicFile.finishWrite(output)
            } catch (_: Exception) {
                atomicFile.failWrite(output)
                return
            }
        } catch (_: Exception) {
            return
        } finally {
            bitmap.recycle()
        }
        prune(context)
    }

    /** The kept preview of a staged item whose copy is gone, if any. */
    fun load(context: Context, uri: Uri, width: Int, height: Int): Bitmap? {
        val file = previewFile(context, uri)?.takeIf { it.isFile } ?: return null
        val decoded = BitmapFactory.decodeFile(file.path) ?: return null
        return MediaThumbnails.scaleBitmapToFit(decoded, width, height)
    }

    private fun previewFile(context: Context, uri: Uri): File? {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT ||
            uri.authority != "${context.packageName}.system_share_files") {
            return null
        }
        val segments = uri.pathSegments
        if (segments.size != 3 || segments[0] != STAGED_ROOT) {
            return null
        }
        val eventId = segments[1]
        val itemName = segments[2]
        if (!isSafeSegment(eventId) || !isSafeSegment(itemName)) {
            return null
        }
        return File(File(root(context), eventId), "$itemName.preview")
    }

    private fun isSafeSegment(value: String): Boolean =
        value != "." && value != ".." && SAFE_SEGMENT.matches(value)

    private fun root(context: Context): File = File(context.filesDir, ROOT)

    private fun prune(context: Context) {
        val root = root(context)
        val previews = root.walkTopDown()
            .filter { it.isFile }
            .sortedByDescending { it.lastModified() }
            .toList()
        var total = 0L
        for (preview in previews) {
            total += preview.length()
            if (total > MAX_TOTAL_BYTES) {
                preview.delete()
            }
        }
        root.listFiles().orEmpty()
            .filter { it.isDirectory && it.list().isNullOrEmpty() }
            .forEach { it.delete() }
    }
}
