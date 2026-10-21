package com.vireen.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The window-stream agent's line to this app, for adb (shell) and root only:
 * - `identity`: this phone's Whisper peer id and identity key, so a desktop
 *   streams it only after the two are paired and trusted;
 * - `report`: how many windows are streamed and to whom, shown as an ongoing
 *   notification (a status-bar chip on Android 16) with a stop button;
 * - `takeStop`: whether that button was pressed, polled by the agent
 *   every second while anything is streamed (which also tells this app the
 *   agent is still there);
 * - `link`: a persistent agent's loopback port and link token, so this
 *   phone can offer its own windows to other devices
 *   ([WindowStreamAgentLink]).
 * While the app runs, [WindowStreamPhonePlugin] passes the same state to
 * its in-app island, whose "stop" goes the same way as the button.
 */
class WindowStreamProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val caller = Binder.getCallingUid()
        if (caller != ROOT_UID && caller != SHELL_UID) {
            throw SecurityException("window stream provider is for adb only")
        }
        val context = context ?: return null
        val identity = Binder.clearCallingIdentity()
        try {
            return when (method) {
                "identity" -> WindowStreamPhoneState.identity(context)
                "report" -> {
                    WindowStreamPhoneState.report(
                        context,
                        windows = extras?.getInt("windows") ?: 0,
                        viewer = extras?.getString("viewer").orEmpty(),
                    )
                    Bundle()
                }
                "takeStop" -> Bundle().apply {
                    putBoolean("stop", WindowStreamPhoneState.takeStop())
                }
                "link" -> Bundle().apply {
                    putBoolean("ok", WindowStreamAgentLink.store(context, extras))
                }
                else -> null
            }
        } finally {
            Binder.restoreCallingIdentity(identity)
        }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    private companion object {
        const val ROOT_UID = 0
        const val SHELL_UID = 2000
    }
}

/** The stop button on the "being streamed" notification. */
class WindowStreamStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        WindowStreamPhoneState.requestStop(context)
    }
}

object WindowStreamPhoneState {
    private const val PREFS = "whisper_window_stream"
    private const val CHANNEL_ID = "whisper.window_stream"
    private const val NOTIFICATION_ID = 7301
    private const val ISLAND_ID = "streamed"
    private const val FLOW_INDIGO = 0xFF5E5CE6.toInt()

    /**
     * The agent asks for the stop button every second while it streams; this
     * long without a word and it is gone (adb unplugged, killed) without
     * saying so, and the notification would otherwise stay forever.
     */
    private const val AGENT_SILENT_MS = 10_000L
    private const val WATCH_EVERY_MS = 2_500L

    private val stopRequested = AtomicBoolean(false)
    @Volatile private var windows = 0
    @Volatile private var viewer = ""

    /** "Stop" was pressed and the windows have not all gone back yet. */
    @Volatile private var stopping = false

    @Volatile private var lastHeard = 0L

    /** Windows put aside when the agent went quiet, back if it speaks again. */
    @Volatile private var quietWindows = 0
    @Volatile private var appContext: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<(Map<String, Any>) -> Unit>()

    private val watchdog = object : Runnable {
        override fun run() {
            val context = appContext ?: return
            if (windows <= 0) {
                return
            }
            if (SystemClock.elapsedRealtime() - lastHeard > AGENT_SILENT_MS) {
                quietWindows = windows
                show(context, 0, viewer)
                return
            }
            main.postDelayed(this, WATCH_EVERY_MS)
        }
    }

    /** What the island shows: windows out there, to whom, whether stopping. */
    fun snapshot(): Map<String, Any> = mapOf(
        "windows" to windows,
        "viewer" to viewer,
        "stopping" to stopping,
    )

    fun addListener(listener: (Map<String, Any>) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (Map<String, Any>) -> Unit) {
        listeners.remove(listener)
    }

    private fun changed() {
        val state = snapshot()
        for (listener in listeners) {
            listener(state)
        }
    }

    /** Saved by the Flutter side at start-up; both values are public. */
    fun publishIdentity(context: Context, peerId: String, identityKey: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("peerId", peerId)
            .putString("identityKey", identityKey)
            .apply()
    }

    fun identity(context: Context): Bundle {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return Bundle().apply {
            putString("peerId", prefs.getString("peerId", "").orEmpty())
            putString("identityKey", prefs.getString("identityKey", "").orEmpty())
            putInt("version", 1)
        }
    }

    fun report(context: Context, windows: Int, viewer: String) {
        lastHeard = SystemClock.elapsedRealtime()
        quietWindows = 0
        show(context, windows, viewer)
    }

    @Synchronized
    private fun show(context: Context, windows: Int, viewer: String) {
        appContext = context.applicationContext
        val started = this.windows == 0 && windows > 0
        this.windows = windows
        this.viewer = viewer
        if (started) {
            stopRequested.set(false)
            stopping = false
        }
        main.removeCallbacks(watchdog)
        val manager = NotificationManagerCompat.from(context)
        if (windows <= 0) {
            stopping = false
            manager.cancel(NOTIFICATION_ID)
            IslandOverlay.remove(ISLAND_ID)
            changed()
            return
        }
        main.postDelayed(watchdog, WATCH_EVERY_MS)
        island(context)
        try {
            manager.notify(NOTIFICATION_ID, build(context, stopping = stopping))
        } catch (_: SecurityException) {
            // Notifications not allowed: streaming still works, unannounced.
        }
        changed()
    }

    /** 后台灵动岛上也挂着:正在流转到哪,一个"停止"。 */
    private fun island(context: Context) {
        val viewerName = viewer.ifBlank { context.getString(R.string.window_stream_other_device) }
        IslandOverlay.put(
            context,
            IslandOverlay.Item(
                id = ISLAND_ID,
                glyph = IslandOverlay.Glyph.FLOW,
                title = context.getString(R.string.window_stream_active_title, viewerName),
                text = if (stopping) {
                    context.getString(R.string.window_stream_stopping)
                } else {
                    context.resources.getQuantityString(R.plurals.window_stream_window_count, windows, windows)
                },
                figure = context.getString(R.string.window_stream_chip),
                buttons = if (stopping) {
                    emptyList()
                } else {
                    listOf(
                        IslandOverlay.Button(
                            context.getString(R.string.window_stream_stop_action),
                            IslandOverlay.Role.DECLINE,
                        ) { requestStop(context) },
                    )
                },
                rank = 50,
            ),
        )
    }

    fun requestStop(context: Context) {
        stopRequested.set(true)
        if (windows > 0) {
            stopping = true
            show(context, windows, viewer)
        }
    }

    fun takeStop(): Boolean {
        lastHeard = SystemClock.elapsedRealtime()
        val quiet = quietWindows
        val context = appContext
        if (quiet > 0 && windows == 0 && context != null) {
            // Only slow, not gone: what it streams is still out there.
            quietWindows = 0
            main.post { if (windows == 0) show(context, quiet, viewer) }
        }
        return stopRequested.getAndSet(false)
    }

    private fun build(context: Context, stopping: Boolean): Notification {
        ensureChannel(context)
        val title = context.getString(
            R.string.window_stream_active_title,
            viewer.ifBlank { context.getString(R.string.window_stream_other_device) },
        )
        val text = if (stopping) {
            context.getString(R.string.window_stream_stopping)
        } else {
            context.resources.getQuantityString(R.plurals.window_stream_window_count, windows, windows)
        }
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getBroadcast(
            context,
            1,
            Intent(context, WindowStreamStopReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_flow)
            .setColor(FLOW_INDIGO)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(open)
        if (!stopping) {
            builder.addAction(0, context.getString(R.string.window_stream_stop_action), stop)
        }
        // Android 16 shows promoted ongoing notifications as a status-bar
        // chip; systems with an island of their own pick it up from there.
        if (Build.VERSION.SDK_INT >= 36 && NotificationManagerCompat.from(context).canPostPromotedNotifications()) {
            builder.setRequestPromotedOngoing(true)
            builder.setShortCriticalText(context.getString(R.string.window_stream_chip))
        }
        return builder.build()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.window_stream_channel),
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) },
        )
    }
}

/**
 * Tells the app's island while it runs that this phone is being streamed,
 * and stops it from there ("停止流转" goes the same way as the notification's
 * button: the agent picks the request up and closes its windows).
 */
class WindowStreamPhonePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private val agent = WindowStreamAgentPlugin()
    private val main = Handler(Looper.getMainLooper())
    private val listener: (Map<String, Any>) -> Unit = { state ->
        main.post { channel?.invokeMethod("state", state) }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        WindowStreamPhoneState.addListener(listener)
        agent.onAttachedToEngine(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        agent.onDetachedFromEngine(binding)
        WindowStreamPhoneState.removeListener(listener)
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "state" -> result.success(WindowStreamPhoneState.snapshot())
            "stop" -> {
                context?.let { WindowStreamPhoneState.requestStop(it) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private companion object {
        const val CHANNEL = "com.vireen.whisper/window_stream_phone"
    }
}
