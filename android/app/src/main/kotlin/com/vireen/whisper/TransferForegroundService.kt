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
import androidx.core.app.NotificationManagerCompat

/**
 * 传输进度前台服务:持有 id=10022 的进度通知。
 * Android 16+ 且系统允许 promoted 通知时走 ProgressStyle + promoted ongoing
 * (状态栏 chip / 锁屏卡片),否则降级为经典 setProgress。
 * 终态时原地把同一条通知更新为可滑走的结果通知,再 detach 停止服务。
 */
class TransferForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.getStringExtra(EXTRA_COMMAND)) {
            COMMAND_PROGRESS -> {
                val notification = buildProgressNotification(
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                    intent.getIntExtra(EXTRA_PROGRESS, 0),
                )
                startForeground(NOTIFICATION_ID, notification)
            }

            COMMAND_TERMINAL -> {
                showTerminal(
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                )
                stopForeground(STOP_FOREGROUND_DETACH)
                stopSelf()
            }

            COMMAND_CANCEL -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                notificationManager().cancel(NOTIFICATION_ID)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun buildProgressNotification(
        title: String,
        text: String,
        progress: Int,
    ): Notification {
        ensureChannel()
        val clamped = progress.coerceIn(0, 100)
        val builder = baseBuilder(title, text)
            .setOngoing(true)
        if (supportsLiveUpdates()) {
            builder.setStyle(
                NotificationCompat.ProgressStyle()
                    .setProgress(clamped)
            )
            builder.setRequestPromotedOngoing(true)
            builder.setShortCriticalText("$clamped%")
        } else {
            builder.setProgress(100, clamped, false)
        }
        return builder.build()
    }

    private fun showTerminal(title: String, text: String) {
        ensureChannel()
        val notification = baseBuilder(title, text)
            .setOngoing(false)
            .setAutoCancel(true)
            .build()
        notificationManager().notify(NOTIFICATION_ID, notification)
    }

    private fun baseBuilder(title: String, text: String): NotificationCompat.Builder {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(buildContentIntent())
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
    }

    private fun supportsLiveUpdates(): Boolean {
        return Build.VERSION.SDK_INT >= 36 &&
            NotificationManagerCompat.from(this).canPostPromotedNotifications()
    }

    private fun buildContentIntent(): PendingIntent {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Whisper Transfer",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "File transfer progress"
            setShowBadge(false)
        }
        notificationManager().createNotificationChannel(channel)
    }

    companion object {
        const val CHANNEL_ID = "whisper.transfer"
        const val NOTIFICATION_ID = 10022
        const val EXTRA_COMMAND = "command"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        const val COMMAND_PROGRESS = "progress"
        const val COMMAND_TERMINAL = "terminal"
        const val COMMAND_CANCEL = "cancel"

        fun buildIntent(context: Context, command: String): Intent {
            return Intent(context, TransferForegroundService::class.java)
                .putExtra(EXTRA_COMMAND, command)
        }
    }
}
