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
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * 传输进度前台服务:持有 id=10022 的进度通知。
 * Android 16+ 且系统允许 promoted 通知时走 ProgressStyle + promoted ongoing
 * (状态栏 chip / 锁屏卡片),否则降级为经典 setProgress。
 * 终态时原地把同一条通知更新为可滑走的结果通知,再 detach 停止服务。
 */
class TransferForegroundService : Service() {
    // channel 名/描述由 Flutter 侧随启动 Intent 传入已本地化文案,缺省回退英文。
    private var channelName: String = DEFAULT_CHANNEL_NAME
    private var channelDescription: String = DEFAULT_CHANNEL_DESCRIPTION

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra(EXTRA_CHANNEL_NAME)
            ?.takeIf { it.isNotBlank() }?.let { channelName = it }
        intent?.getStringExtra(EXTRA_CHANNEL_DESCRIPTION)
            ?.takeIf { it.isNotBlank() }?.let { channelDescription = it }
        when (intent?.getStringExtra(EXTRA_COMMAND)) {
            COMMAND_PROGRESS -> {
                val notification = buildProgressNotification(
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                    intent.getIntExtra(EXTRA_PROGRESS, 0),
                )
                startForeground(NOTIFICATION_ID, notification)
            }

            COMMAND_STATUS -> {
                // 停滞/部分收尾:更新文案但服务保活,后台恢复的进度更新
                // 无需重新拉起 FGS(Android 12+ 后台拉起会被拒)。
                val notification = buildStatusNotification(
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                )
                startForeground(NOTIFICATION_ID, notification)
            }

            COMMAND_TERMINAL -> {
                // startForegroundService 契约:本次启动必须先 startForeground
                // 一次再退场,否则服务冷启动收终态会抛 RemoteServiceException。
                val notification = buildTerminalNotification(
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                )
                startForeground(NOTIFICATION_ID, notification)
                stopForeground(STOP_FOREGROUND_DETACH)
                // detach 后重发一次,确保通知脱离 FGS 标志、可滑走
                notificationManager().notify(NOTIFICATION_ID, notification)
                stopSelf()
            }

            COMMAND_CANCEL -> {
                startForeground(
                    NOTIFICATION_ID,
                    buildStatusNotification("", ""),
                )
                stopForeground(STOP_FOREGROUND_REMOVE)
                notificationManager().cancel(NOTIFICATION_ID)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    // Android 15+ dataSync 前台服务超时兜底:预算(默认 6 小时)耗尽时系统
    // 回调 onTimeout,必须立即退出前台并停止,否则会抛
    // ForegroundServiceDidNotStopInTimeException 直接杀进程。
    // 走 COMMAND_CANCEL 的既有收尾:摘掉通知、结束服务。
    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        notificationManager().cancel(NOTIFICATION_ID)
        stopSelf()
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
        } else {
            builder.setProgress(100, clamped, false)
        }
        return builder.build()
    }

    private fun buildStatusNotification(title: String, text: String): Notification {
        ensureChannel()
        return baseBuilder(title, text)
            .setOngoing(true)
            .build()
    }

    private fun buildTerminalNotification(title: String, text: String): Notification {
        ensureChannel()
        return baseBuilder(title, text)
            .setOngoing(false)
            .setAutoCancel(true)
            .build()
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
            channelName,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = channelDescription
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
        const val EXTRA_CHANNEL_NAME = "channelName"
        const val EXTRA_CHANNEL_DESCRIPTION = "channelDescription"
        private const val DEFAULT_CHANNEL_NAME = "Whisper Transfer"
        private const val DEFAULT_CHANNEL_DESCRIPTION = "File transfer progress"
        const val COMMAND_PROGRESS = "progress"
        const val COMMAND_STATUS = "status"
        const val COMMAND_TERMINAL = "terminal"
        const val COMMAND_CANCEL = "cancel"

        fun buildIntent(context: Context, command: String): Intent {
            return Intent(context, TransferForegroundService::class.java)
                .putExtra(EXTRA_COMMAND, command)
        }
    }
}
