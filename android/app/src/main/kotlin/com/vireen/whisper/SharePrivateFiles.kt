package com.vireen.whisper

import android.content.Context
import android.net.Uri
import android.system.Os
import java.io.File

/**
 * Whether a shared content URI points into Whisper's own private storage.
 *
 * Whisper reads what another app shares with Whisper's own rights, and some
 * of Whisper's file providers can name any file (open_filex serves the root).
 * So an app could share `content://<whisper provider>/root/data/.../databases/...`
 * and have Whisper send its own database, keys or agent link to a peer. Shared
 * storage and MediaStore items are not affected.
 */
internal object SharePrivateFiles {
    fun isPrivate(context: Context, uri: Uri): Boolean {
        val authority = uri.authority ?: return false
        val provider = context.packageManager.resolveContentProvider(authority, 0)
        if (provider == null || provider.packageName != context.packageName) {
            return false
        }
        return try {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                val path = File(Os.readlink("/proc/self/fd/${descriptor.fd}")).canonicalPath
                privateRoots(context).any { root -> path == root || path.startsWith("$root/") }
            } ?: true
        } catch (_: Exception) {
            // One of Whisper's own providers, and where it leads can't be told.
            true
        }
    }

    private fun privateRoots(context: Context): List<String> {
        val dirs = listOf(
            File(context.applicationInfo.dataDir),
            context.createDeviceProtectedStorageContext().dataDir,
            File("/data/data/${context.packageName}"),
        )
        return dirs.flatMap { listOf(it.absolutePath, it.canonicalPath) }.distinct()
    }
}
