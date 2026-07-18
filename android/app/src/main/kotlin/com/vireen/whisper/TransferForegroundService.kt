package com.vireen.whisper

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.annotation.RequiresApi

/**
 * 传输进度前台服务:与其他 Whisper 前台任务共用一条状态通知。
 * Android 16+ 且系统允许 promoted 通知时走 ProgressStyle + promoted ongoing
 * (状态栏 chip / 锁屏卡片),否则降级为经典 setProgress。
 * 终态时原地把同一条通知更新为可滑走的结果通知,再 detach 停止服务。
 */
class TransferForegroundService : Service() {
    // channel 名/描述由 Flutter 侧随启动 Intent 传入已本地化文案,缺省回退英文。
    private var channelName: String = DEFAULT_CHANNEL_NAME
    private var channelDescription: String = DEFAULT_CHANNEL_DESCRIPTION
    private var registered = false
    @Volatile
    private var acceptsDirectCommands = true

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        acceptsDirectCommands = true
        activeInstance = this
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        acceptSystemCommand(intent)
        return START_NOT_STICKY
    }

    @Synchronized
    private fun acceptSystemCommand(intent: Intent?) {
        // A real service start revives the component even if an older
        // generation requested stopSelf. Direct calls do not have that
        // lifecycle guarantee, so only system-delivered starts reopen it.
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
        intent?.getStringExtra(EXTRA_CHANNEL_NAME)
            ?.takeIf { it.isNotBlank() }?.let { channelName = it }
        intent?.getStringExtra(EXTRA_CHANNEL_DESCRIPTION)
            ?.takeIf { it.isNotBlank() }?.let { channelDescription = it }
        when (intent?.getStringExtra(EXTRA_COMMAND)) {
            COMMAND_PROGRESS -> {
                val notification = UnifiedForegroundNotification.setTransferProgress(
                    this,
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                    intent.getIntExtra(EXTRA_PROGRESS, 0),
                    channelName,
                    channelDescription,
                )
                registered = true
                startForeground(NOTIFICATION_ID, notification)
            }

            COMMAND_STATUS -> {
                // 停滞/部分收尾:更新文案但服务保活,后台恢复的进度更新
                // 无需重新拉起 FGS(Android 12+ 后台拉起会被拒)。
                val notification = UnifiedForegroundNotification.setTransferStatus(
                    this,
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                    channelName,
                    channelDescription,
                )
                registered = true
                startForeground(NOTIFICATION_ID, notification)
            }

            COMMAND_TERMINAL -> {
                // startForegroundService 契约:本次启动必须先 startForeground
                // 一次再退场,否则服务冷启动收终态会抛 RemoteServiceException。
                val finish = UnifiedForegroundNotification.finishTransfer(
                    this,
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                )
                registered = false
                beginStopping()
                startForeground(NOTIFICATION_ID, finish.notification)
                stopForeground(STOP_FOREGROUND_DETACH)
                if (finish.hasForegroundOwner) {
                    UnifiedForegroundNotification.publishCurrent(this)
                } else {
                    // detach 后重发一次,确保通知脱离 FGS 标志、可滑走
                    notificationManager().notify(NOTIFICATION_ID, finish.notification)
                }
                stopSelf()
            }

            COMMAND_CANCEL -> {
                val current = UnifiedForegroundNotification.cancelTransfer(this)
                registered = false
                beginStopping()
                startForeground(
                    NOTIFICATION_ID,
                    current ?: UnifiedForegroundNotification.bootstrap(this),
                )
                if (current == null) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    notificationManager().cancel(NOTIFICATION_ID)
                } else {
                    stopForeground(STOP_FOREGROUND_DETACH)
                    UnifiedForegroundNotification.publishCurrent(this)
                }
                stopSelf()
            }
        }
    }

    // Android 15+ dataSync 前台服务超时兜底:预算(默认 6 小时)耗尽时系统
    // 回调 onTimeout,必须立即退出前台并停止,否则会抛
    // ForegroundServiceDidNotStopInTimeException 直接杀进程。
    // 走 COMMAND_CANCEL 的既有收尾:摘掉通知、结束服务。
    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    override fun onTimeout(startId: Int, fgsType: Int) {
        registered = false
        beginStopping()
        val current = UnifiedForegroundNotification.clearTransfer(this)
        if (current == null) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            notificationManager().cancel(NOTIFICATION_ID)
        } else {
            stopForeground(STOP_FOREGROUND_DETACH)
            UnifiedForegroundNotification.publishCurrent(this)
        }
        stopSelf()
    }

    override fun onDestroy() {
        beginStopping()
        isRunning = false
        if (activeInstance === this) {
            activeInstance = null
        }
        if (registered) {
            registered = false
            stopForeground(STOP_FOREGROUND_DETACH)
            UnifiedForegroundNotification.clearTransfer(this)
            UnifiedForegroundNotification.publishCurrent(this)
        }
        super.onDestroy()
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    companion object {
        const val NOTIFICATION_ID = UnifiedForegroundNotification.NOTIFICATION_ID
        @Volatile
        var isRunning = false
            private set
        @Volatile
        private var activeInstance: TransferForegroundService? = null

        fun deliverToRunning(intent: Intent): Boolean {
            val service = activeInstance ?: return false
            return service.deliverCommand(intent)
        }
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
