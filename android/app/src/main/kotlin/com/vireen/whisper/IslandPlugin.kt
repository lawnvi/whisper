package com.vireen.whisper

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 在后台需要用户回答的事(别的设备想浏览文件、送来窗口):Dart 说"问一下",
 * 这里同时放上后台灵动岛(展开的卡片)和一条带按钮的通知——系统有自己的岛时
 * (Android 16 实时更新)通知就出现在那里;岛上看得见时通知不弹横幅。不管在
 * 哪里点了按钮,都回给 Dart 的 `answer`。
 */
class IslandPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        active = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        if (active === this) {
            active = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ask" -> result.success(ask(call))
            "settle" -> {
                settle(context, call.argument<String>("id").orEmpty())
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ask(call: MethodCall): Boolean {
        val id = call.argument<String>("id")?.takeIf { it.isNotBlank() } ?: return false
        val title = call.argument<String>("title").orEmpty()
        val text = call.argument<String>("text").orEmpty()
        val figure = call.argument<String>("figure").orEmpty()
        val glyph = when (call.argument<String>("glyph")) {
            "folder" -> IslandOverlay.Glyph.FOLDER
            "window" -> IslandOverlay.Glyph.FLOW
            "phone" -> IslandOverlay.Glyph.PHONE
            else -> IslandOverlay.Glyph.COMPUTER
        }
        val timeout = call.argument<Number>("timeoutMs")?.toLong()
        val buttons = call.argument<List<Map<String, Any?>>>("buttons").orEmpty().mapNotNull {
            val button = it["id"] as? String ?: return@mapNotNull null
            Triple(
                button,
                it["label"] as? String ?: button,
                when (it["role"]) {
                    "decline" -> IslandOverlay.Role.DECLINE
                    "accept" -> IslandOverlay.Role.ACCEPT
                    "primary" -> IslandOverlay.Role.PRIMARY
                    else -> IslandOverlay.Role.NEUTRAL
                },
            )
        }
        val notificationId = notificationIdOf(id)
        val island = IslandOverlay.presents(context)
        ensureChannel(call.argument<String>("channelName") ?: title)
        val builder = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL)
            .setSmallIcon(
                when (glyph) {
                    IslandOverlay.Glyph.FOLDER -> R.drawable.ic_stat_folder
                    IslandOverlay.Glyph.FLOW -> R.drawable.ic_stat_flow
                    else -> R.drawable.ic_stat_whisper
                },
            )
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setColor(BLUE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(answerIntent(id, OPEN, notificationId * 8))
        if (island) {
            builder.setSilent(true)
        }
        if (timeout != null) {
            builder.setTimeoutAfter(timeout)
        }
        buttons.forEachIndexed { index, (button, label, _) ->
            builder.addAction(0, label, answerIntent(id, button, notificationId * 8 + index + 1))
        }
        if (Build.VERSION.SDK_INT >= 36 &&
            NotificationManagerCompat.from(context).canPostPromotedNotifications()
        ) {
            builder.setRequestPromotedOngoing(true)
            if (figure.isNotBlank() && NotificationArt.islandShowsShortText()) {
                builder.setShortCriticalText(figure)
            }
        } else {
            // 普通通知右边是对方的头像;系统的岛展开后只留左边的图标,
            // 右边再放一个就重复了。
            call.argument<String>("platform")?.takeIf { it.isNotBlank() }?.let {
                builder.setLargeIcon(NotificationArt.device(it))
            }
        }
        IslandOverlay.put(
            context,
            IslandOverlay.Item(
                id = islandIdOf(id),
                glyph = glyph,
                title = title,
                text = text,
                figure = figure,
                buttons = buttons.map { (button, label, role) ->
                    IslandOverlay.Button(label, role) { answer(context, id, button) }
                },
                urgent = true,
                rank = call.argument<Number>("rank")?.toInt() ?: 95,
                onOpen = { answer(context, id, OPEN) },
            ),
            timeout,
        )
        return try {
            NotificationManagerCompat.from(context).notify(notificationId, builder.build())
            true
        } catch (_: SecurityException) {
            // 通知不让发:岛上还有。
            true
        }
    }

    private fun ensureChannel(name: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL, name, NotificationManager.IMPORTANCE_HIGH).apply {
                setShowBadge(false)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            },
        )
    }

    private fun answerIntent(id: String, button: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, IslandActionReceiver::class.java)
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_BUTTON, button)
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        const val CHANNEL = "com.vireen.whisper/island"
        private const val NOTIFICATION_CHANNEL = "whisper.requests"
        const val EXTRA_ID = "id"
        const val EXTRA_BUTTON = "button"

        /** 点了卡片或通知本身:打开 Whisper,由它在应用里接着问。 */
        const val OPEN = "open"
        private const val BLUE = 0xFF0A84FF.toInt()

        @Volatile
        private var active: IslandPlugin? = null
        private val main = Handler(Looper.getMainLooper())

        private fun islandIdOf(id: String) = "ask:$id"

        /** 每个问题一个固定的通知 id,避开其他通知用的小数字。 */
        fun notificationIdOf(id: String): Int = 0x5100000 + (id.hashCode() and 0xFFFFF)

        fun settle(context: Context, id: String) {
            if (id.isBlank()) {
                return
            }
            NotificationManagerCompat.from(context).cancel(notificationIdOf(id))
            IslandOverlay.remove(islandIdOf(id))
        }

        /** 不管在岛上还是通知上点的:收起这个问题,告诉 Dart。 */
        fun answer(context: Context, id: String, button: String) {
            settle(context, id)
            if (button == OPEN) {
                IslandOverlay.open(context)
            }
            main.post {
                active?.channel?.invokeMethod(
                    "answer",
                    mapOf("id" to id, "button" to button),
                )
            }
        }
    }
}

/** 通知上的按钮(和点通知本身)。 */
class IslandActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(IslandPlugin.EXTRA_ID) ?: return
        val button = intent.getStringExtra(IslandPlugin.EXTRA_BUTTON) ?: return
        IslandPlugin.answer(context, id, button)
    }
}
