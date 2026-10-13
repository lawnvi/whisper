package com.vireen.whisper

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.Size

/** Downscaled stills of local photos and videos. */
internal object MediaThumbnails {
    fun create(context: Context, uri: Uri, width: Int, height: Int): Bitmap? {
        if (uri.scheme == "file") {
            val retriever = MediaMetadataRetriever()
            return try {
                retriever.setDataSource(uri.path)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    retriever.getScaledFrameAtTime(
                        -1, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, width, height,
                    )
                } else {
                    retriever.frameAtTime?.let { scaleBitmapToFit(it, width, height) }
                }
            } finally {
                retriever.release()
            }
        }
        val mimeType = context.contentResolver.getType(uri).orEmpty()
        if (mimeType.startsWith("video/")) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    return context.contentResolver.loadThumbnail(uri, Size(width, height), null)
                } catch (_: Exception) {
                    // Plain file providers, such as the one holding shared
                    // items, cannot serve a video as an image; read a frame.
                }
            }
            val retriever = MediaMetadataRetriever()
            return try {
                retriever.setDataSource(context, uri)
                retriever.frameAtTime?.let { scaleBitmapToFit(it, width, height) }
            } finally {
                retriever.release()
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return ImageDecoder.decodeBitmap(
                ImageDecoder.createSource(context.contentResolver, uri),
            ) { decoder, info, _ ->
                val sourceWidth = info.size.width
                val sourceHeight = info.size.height
                val scale = minOf(
                    1f,
                    width.toFloat() / sourceWidth.toFloat(),
                    height.toFloat() / sourceHeight.toFloat(),
                )
                decoder.setTargetSize(
                    (sourceWidth * scale).toInt().coerceAtLeast(1),
                    (sourceHeight * scale).toInt().coerceAtLeast(1),
                )
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri).use { input ->
            BitmapFactory.decodeStream(input, null, bounds)
        }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            return null
        }
        var sampleSize = 1
        while (bounds.outWidth / (sampleSize * 2) >= width &&
            bounds.outHeight / (sampleSize * 2) >= height) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        val decoded = context.contentResolver.openInputStream(uri).use { input ->
            BitmapFactory.decodeStream(input, null, options)
        } ?: return null
        return scaleBitmapToFit(decoded, width, height)
    }

    fun scaleBitmapToFit(bitmap: Bitmap, width: Int, height: Int): Bitmap {
        val scale = minOf(
            1f,
            width.toFloat() / bitmap.width.toFloat(),
            height.toFloat() / bitmap.height.toFloat(),
        )
        if (scale >= 1f) {
            return bitmap
        }
        val scaled = Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * scale).toInt().coerceAtLeast(1),
            (bitmap.height * scale).toInt().coerceAtLeast(1),
            true,
        )
        if (scaled !== bitmap) {
            bitmap.recycle()
        }
        return scaled
    }
}
