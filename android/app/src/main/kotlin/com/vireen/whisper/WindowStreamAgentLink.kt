package com.vireen.whisper

import android.content.Context
import android.os.Bundle
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArraySet

/**
 * How to reach this phone's persistent whisper-agent: loopback port and link
 * token, pushed by the agent itself through [WindowStreamProvider] (which
 * only the shell user and root may call). Kept in the app's no-backup
 * folder so a restarted Whisper finds the agent again without asking; the
 * token never leaves this app (the agent proves it, see AppLink.java).
 */
object WindowStreamAgentLink {
    private const val FILE = "window_stream_agent_link.json"
    private const val TOKEN_BYTES = 32

    private val listeners = CopyOnWriteArraySet<(Map<String, Any>) -> Unit>()

    fun addListener(listener: (Map<String, Any>) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (Map<String, Any>) -> Unit) {
        listeners.remove(listener)
    }

    /** From the agent's `link` call; false when the extras are malformed. */
    fun store(context: Context, extras: Bundle?): Boolean {
        val port = extras?.getInt("port", 0) ?: 0
        val token = extras?.getByteArray("token")
        if (port !in 1..65535 || token == null || token.size != TOKEN_BYTES) {
            return false
        }
        val json = JSONObject()
            .put("port", port)
            .put("token", Base64.encodeToString(token, Base64.NO_WRAP))
            .put("pid", extras.getInt("pid", 0))
            .put("protocol", extras.getInt("protocol", 0))
            .put("version", extras.getString("version").orEmpty())
            .put("jarSha", extras.getString("jarSha").orEmpty())
            .put("at", System.currentTimeMillis())
        val file = file(context)
        val temp = File(file.parentFile, "$FILE.tmp")
        temp.writeText(json.toString())
        if (!temp.renameTo(file)) {
            temp.delete()
            return false
        }
        val link = toMap(json) ?: return false
        for (listener in listeners) {
            listener(link)
        }
        return true
    }

    fun load(context: Context): Map<String, Any>? {
        val file = file(context)
        if (!file.isFile) {
            return null
        }
        return try {
            toMap(JSONObject(file.readText()))
        } catch (_: Exception) {
            null
        }
    }

    fun clear(context: Context) {
        file(context).delete()
    }

    private fun file(context: Context): File = File(context.noBackupFilesDir, FILE)

    private fun toMap(json: JSONObject): Map<String, Any>? {
        val token = try {
            Base64.decode(json.optString("token"), Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            return null
        }
        if (token.size != TOKEN_BYTES) {
            return null
        }
        return mapOf(
            "port" to json.optInt("port"),
            "token" to token,
            "pid" to json.optInt("pid"),
            "protocol" to json.optInt("protocol"),
            "version" to json.optString("version"),
            "jarSha" to json.optString("jarSha"),
            "at" to json.optLong("at"),
        )
    }
}
