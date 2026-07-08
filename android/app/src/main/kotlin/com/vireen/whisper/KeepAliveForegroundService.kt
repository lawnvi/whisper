package com.vireen.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class KeepAliveForegroundService : Service() {
    // channel 名/描述由 Flutter 侧随启动 Intent 传入已本地化文案,缺省回退英文。
    // 文案同时持久化:START_STICKY 空 intent 重建与首启 onCreate 抢跑时,
    // ensureChannel 不至于用英文缺省名把系统设置里已本地化的渠道名改回去。
    private var channelName: String = DEFAULT_CHANNEL_NAME
    private var channelDescription: String = DEFAULT_CHANNEL_DESCRIPTION

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.getString(PREF_CHANNEL_NAME, null)
            ?.takeIf { it.isNotBlank() }?.let { channelName = it }
        prefs.getString(PREF_CHANNEL_DESCRIPTION, null)
            ?.takeIf { it.isNotBlank() }?.let { channelDescription = it }
        startForeground(
            NOTIFICATION_ID,
            buildNotification(
                DEFAULT_TITLE,
                DEFAULT_DESCRIPTION,
                NO_PROGRESS,
                true
            )
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
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
        startForeground(
            NOTIFICATION_ID,
            buildNotification(title, description, progress, indeterminateProgress)
        )
        return START_STICKY
    }

    override fun onDestroy() {
        @Suppress("DEPRECATION")
        stopForeground(true)
        super.onDestroy()
    }

    private fun buildNotification(
        title: String,
        description: String,
        progressValue: Int,
        indeterminateProgress: Boolean
    ): Notification {
        ensureChannel()
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(description)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(buildContentIntent())
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)

        if (indeterminateProgress) {
            builder.setProgress(100, 0, true)
        } else if (progressValue != NO_PROGRESS) {
            val progress = progressValue.coerceIn(0, 100)
            builder.setProgress(100, progress, false)
        }

        return builder.build()
    }

    private fun buildContentIntent(): PendingIntent {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        return PendingIntent.getActivity(this, 0, launchIntent, flags)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            channelName,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = channelDescription
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "whisper.keep_alive"
        private const val NOTIFICATION_ID = 10021
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
