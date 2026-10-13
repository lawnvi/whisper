package com.vireen.whisper

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import java.io.File

/**
 * Photos and videos shared from a gallery are usually in the media store.
 * When Whisper may read shared storage, a shared item is sent from there, as
 * files picked inside the app are, so the chat can still open it later and no
 * copy is kept. Anything else is copied in, because the sharing app's grant
 * ends with the app process.
 */
internal object SharedMediaStoreSource {
    private val PICKER_SEGMENTS = setOf("picker", "picker_get_content")

    class Resolved(val uri: Uri, val size: Long)

    /** A lasting media store entry with the same bytes as [source], if any. */
    fun resolve(
        context: Context,
        source: Uri,
        displayName: String,
        expectedSize: Long?
    ): Resolved? {
        if (!canReadSharedStorage(context)) {
            return null
        }
        val candidate = when {
            isMediaStoreItem(source) -> source
            else -> embeddedMediaStoreItem(source)
                ?: sourcePath(context, source)?.let { findByPath(context, it) }
                ?: findByNameAndSize(context, displayName, expectedSize)
        } ?: return null
        val size = readableSize(context, candidate) ?: return null
        // An edited or re-encoded share is not the stored original.
        if (expectedSize != null && expectedSize != size) {
            return null
        }
        return Resolved(candidate, size)
    }

    private fun canReadSharedStorage(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }

    /** Photo picker uris only work while their grant lasts. */
    private fun isMediaStoreItem(uri: Uri): Boolean =
        uri.authority == MediaStore.AUTHORITY &&
            uri.pathSegments.size >= 2 &&
            uri.pathSegments.first() !in PICKER_SEGMENTS

    /** Some galleries wrap the media store uri inside their own. */
    private fun embeddedMediaStoreItem(source: Uri): Uri? =
        source.pathSegments
            .filter { it.startsWith("content://${MediaStore.AUTHORITY}/") }
            .map(Uri::parse)
            .firstOrNull(::isMediaStoreItem)

    private fun sourcePath(context: Context, source: Uri): String? =
        try {
            context.contentResolver.query(
                source,
                arrayOf(MediaStore.MediaColumns.DATA),
                null,
                null,
                null
            )?.use { cursor ->
                val index = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                    cursor.getString(index)
                } else {
                    null
                }
            }?.takeIf { it.isNotBlank() && File(it).isFile }
        } catch (_: Exception) {
            null
        }

    private fun findByPath(context: Context, path: String): Uri? =
        findOne(context, "${MediaStore.MediaColumns.DATA} = ?", arrayOf(path))

    private fun findByNameAndSize(context: Context, name: String, size: Long?): Uri? {
        if (size == null || size <= 0 || name.isBlank()) {
            return null
        }
        return findOne(
            context,
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.SIZE} = ?",
            arrayOf(name, size.toString())
        )
    }

    /** The only entry that matches, so a guess never picks the wrong file. */
    private fun findOne(context: Context, selection: String, args: Array<String>): Uri? =
        try {
            context.contentResolver.query(
                MediaStore.Files.getContentUri("external"),
                arrayOf(MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.MEDIA_TYPE),
                selection,
                args,
                null
            )?.use { cursor ->
                if (cursor.count != 1 || !cursor.moveToFirst()) {
                    return@use null
                }
                val id = cursor.getLong(0)
                val collection = when (cursor.getInt(1)) {
                    MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE ->
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                    MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO ->
                        MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    MediaStore.Files.FileColumns.MEDIA_TYPE_AUDIO ->
                        MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                    else -> MediaStore.Files.getContentUri("external")
                }
                ContentUris.withAppendedId(collection, id)
            }
        } catch (_: Exception) {
            null
        }

    private fun readableSize(context: Context, uri: Uri): Long? =
        try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.statSize.takeIf { it >= 0 }
            }
        } catch (_: Exception) {
            null
        }
}
