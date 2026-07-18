package com.vireen.whisper

import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.PowerManager

class KeepAliveForegroundService : Service() {
    // channel 名/描述由 Flutter 侧随启动 Intent 传入已本地化文案,缺省回退英文。
    // 文案同时持久化:onCreate 早于 onStartCommand 运行时,
    // ensureChannel 不至于用英文缺省名把系统设置里已本地化的渠道名改回去。
    private var channelName: String = DEFAULT_CHANNEL_NAME
    private var channelDescription: String = DEFAULT_CHANNEL_DESCRIPTION
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    @Volatile
    private var acceptsDirectCommands = true

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        acceptsDirectCommands = true
        activeInstance = this
        isRunning = true
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.getString(PREF_CHANNEL_NAME, null)
            ?.takeIf { it.isNotBlank() }?.let { channelName = it }
        prefs.getString(PREF_CHANNEL_DESCRIPTION, null)
            ?.takeIf { it.isNotBlank() }?.let { channelDescription = it }
        startForeground(
            NOTIFICATION_ID,
            UnifiedForegroundNotification.bootstrap(this),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        acceptSystemCommand(intent)
        return START_NOT_STICKY
    }

    @Synchronized
    private fun acceptSystemCommand(intent: Intent?) {
        acceptsDirectCommands = true
        handleCommand(intent)
    }

    @Synchronized
    private fun deliverCommand(intent: Intent): Boolean {
        if (!acceptsDirectCommands) {
            return false
        }
        handleCommand(intent)
        return true
    }

    @Synchronized
    private fun beginStopping() {
        acceptsDirectCommands = false
    }

    private fun handleCommand(intent: Intent?) {
        val extraChannelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME)
            ?.takeIf { it.isNotBlank() }
        val extraChannelDescription = intent?.getStringExtra(EXTRA_CHANNEL_DESCRIPTION)
            ?.takeIf { it.isNotBlank() }
        if (extraChannelName != null || extraChannelDescription != null) {
            extraChannelName?.let { channelName = it }
            extraChannelDescription?.let { channelDescription = it }
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                .putString(PREF_CHANNEL_NAME, channelName)
                .putString(PREF_CHANNEL_DESCRIPTION, channelDescription)
                .apply()
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: DEFAULT_TITLE
        val description = intent?.getStringExtra(EXTRA_DESCRIPTION) ?: DEFAULT_DESCRIPTION
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, NO_PROGRESS) ?: NO_PROGRESS
        val indeterminateProgress =
            intent?.getBooleanExtra(EXTRA_INDETERMINATE_PROGRESS, false) ?: false
        val notification = UnifiedForegroundNotification.setKeepAlive(
            this,
            title,
            description,
            progress.takeUnless { it == NO_PROGRESS },
            indeterminateProgress,
            channelName,
            channelDescription,
        )
        startForeground(NOTIFICATION_ID, notification)
        acquireResourceLocks()
    }

    override fun onDestroy() {
        beginStopping()
        isRunning = false
        if (activeInstance === this) {
            activeInstance = null
        }
        releaseResourceLocks()
        stopForeground(STOP_FOREGROUND_DETACH)
        UnifiedForegroundNotification.clearKeepAlive(this)
        UnifiedForegroundNotification.publishCurrent(this)
        super.onDestroy()
    }

    /**
     * The service only runs while background keep-alive is enabled. These
     * non-reference-counted locks therefore follow the same lifecycle and do
     * not outlive the user's setting. A vendor may reject either lock, so each
     * resource is acquired independently and the foreground service continues.
    */
    @Suppress("DEPRECATION")
    private fun acquireResourceLocks() {
        try {
            if (wakeLock?.isHeld != true) {
                val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
                val lock = wakeLock ?: manager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "$packageName:$WAKE_LOCK_TAG"
                ).apply { setReferenceCounted(false) }
                lock.acquire()
                wakeLock = lock
            }
            } catch (_: RuntimeException) {
                // The foreground service remains useful if this vendor rejects the lock.
            }

        try {
            if (wifiLock?.isHeld != true) {
                val manager = applicationContext.getSystemService(Context.WIFI_SERVICE)
                    as WifiManager
                val lock = wifiLock ?: manager.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "$packageName:$WIFI_LOCK_TAG"
                ).apply { setReferenceCounted(false) }
                lock.acquire()
                wifiLock = lock
            }
            } catch (_: RuntimeException) {
                // The CPU lock can still preserve the Dart server independently.
            }
    }

    private fun releaseResourceLocks() {
        val heldWifiLock = wifiLock
        wifiLock = null
        try {
            if (heldWifiLock?.isHeld == true) {
                heldWifiLock.release()
            }
        } catch (_: RuntimeException) {
            // The service is already ending; never prevent the remaining cleanup.
        }

        val heldWakeLock = wakeLock
        wakeLock = null
        try {
            if (heldWakeLock?.isHeld == true) {
                heldWakeLock.release()
            }
        } catch (_: RuntimeException) {
            // The service is already ending; never prevent the remaining cleanup.
        }
    }

    companion object {
        private const val WAKE_LOCK_TAG = "lan-server"
        private const val WIFI_LOCK_TAG = "lan-wifi"
        private const val NOTIFICATION_ID = UnifiedForegroundNotification.NOTIFICATION_ID
        private const val NO_PROGRESS = -1
        private const val DEFAULT_TITLE = "Whisper"
        private const val DEFAULT_DESCRIPTION = "Keeping connection alive"
        private const val DEFAULT_CHANNEL_NAME = "Whisper Keep Alive"
        private const val DEFAULT_CHANNEL_DESCRIPTION =
            "Keeps Whisper connected while it runs in the background"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_DESCRIPTION = "description"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_INDETERMINATE_PROGRESS = "indeterminateProgress"
        private const val EXTRA_CHANNEL_NAME = "channelName"
        private const val EXTRA_CHANNEL_DESCRIPTION = "channelDescription"
        private const val PREFS_NAME = "whisper.keep_alive.channel"
        private const val PREF_CHANNEL_NAME = "channelName"
        private const val PREF_CHANNEL_DESCRIPTION = "channelDescription"
        @Volatile
        var isRunning = false
            private set
        @Volatile
        private var activeInstance: KeepAliveForegroundService? = null

        fun deliverToRunning(intent: Intent): Boolean {
            val service = activeInstance ?: return false
            return service.deliverCommand(intent)
        }

        fun prepareToStop() {
            activeInstance?.beginStopping()
        }

        fun buildIntent(
            context: Context,
            title: String,
            description: String,
            progress: Int?,
            indeterminateProgress: Boolean,
            channelName: String = "",
            channelDescription: String = ""
        ): Intent {
            return Intent(context, KeepAliveForegroundService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_DESCRIPTION, description)
                if (progress != null) {
                    putExtra(EXTRA_PROGRESS, progress)
                }
                putExtra(EXTRA_INDETERMINATE_PROGRESS, indeterminateProgress)
                putExtra(EXTRA_CHANNEL_NAME, channelName)
                putExtra(EXTRA_CHANNEL_DESCRIPTION, channelDescription)
            }
        }
    }
}
