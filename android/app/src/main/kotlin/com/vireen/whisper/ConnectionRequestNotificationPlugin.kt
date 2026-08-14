package com.vireen.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ConnectionRequestNotificationPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        removeObsoletePhoneAccounts()
        channel = MethodChannel(
            binding.binaryMessenger,
            "com.vireen.whisper/connection_request_notifications"
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "showConnectionAlert" -> {
                val shown = try {
                    showConnectionAlert(call)
                } catch (_: RuntimeException) {
                    false
                }
                result.success(shown)
            }
            "dismissConnectionAlert" -> {
                val notificationId = call.argument<Int>("notificationId")
                if (notificationId == null) {
                    result.success(false)
                } else {
                    NotificationManagerCompat.from(context).cancel(notificationId)
                    result.success(true)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun showConnectionAlert(call: MethodCall): Boolean {
        val notificationId = call.argument<Int>("notificationId") ?: return false
        if (call.argument<String>("peerId").isNullOrBlank()) return false
        val deviceName = call.argument<String>("deviceName")?.takeIf { it.isNotBlank() }
            ?: return false
        val platform = call.argument<String>("platform").orEmpty()
        val verificationText = call.argument<String>("verificationText")
            ?.takeIf { it.isNotBlank() } ?: return false
        val title = call.argument<String>("title") ?: deviceName
        val payload = call.argument<String>("payload") ?: return false
        val rejectActionId = call.argument<String>("rejectActionId") ?: return false
        val answerActionId = call.argument<String>("answerActionId") ?: return false
        val answerShowsUserInterface =
            call.argument<Boolean>("answerShowsUserInterface") ?: false
        val channelName = call.argument<String>("channelName") ?: title
        val channelDescription = call.argument<String>("channelDescription") ?: channelName

        ensureChannel(channelName, channelDescription)
        val rejectIntent = actionPendingIntent(
            notificationId = notificationId,
            requestOffset = 1,
            actionId = rejectActionId,
            payload = payload,
            showsUserInterface = false,
        )
        val answerIntent = actionPendingIntent(
            notificationId = notificationId,
            requestOffset = 2,
            actionId = answerActionId,
            payload = payload,
            showsUserInterface = answerShowsUserInterface,
        )
        val style = NotificationCompat.BigTextStyle()
            .setBigContentTitle(deviceName)
            .bigText(verificationText)
            .setSummaryText(title)
        val rejectAction = NotificationCompat.Action.Builder(
            0,
            context.getString(R.string.connection_alert_reject_action),
            rejectIntent,
        )
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_DELETE)
            .build()
        val answerAction = NotificationCompat.Action.Builder(
            0,
            context.getString(R.string.connection_alert_accept_action),
            answerIntent,
        )
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ)
            .setShowsUserInterface(answerShowsUserInterface)
            .build()
        val openIntent = contentPendingIntent(notificationId, payload)
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_whisper)
            .setLargeIcon(deviceAvatar(platform))
            .setContentTitle(deviceName)
            .setContentText(verificationText)
            .setSubText(title)
            .setTicker("$deviceName · $verificationText")
            .setContentIntent(openIntent)
            .setStyle(style)
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setColor(BRAND_BLUE)
            .setColorized(false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setTimeoutAfter(TIMEOUT_MILLIS)
            .addAction(rejectAction)
            .addAction(answerAction)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder
                .setSound(Settings.System.DEFAULT_NOTIFICATION_URI)
                .setVibrate(VIBRATION_PATTERN)
        }
        val notification = builder.build()

        return try {
            NotificationManagerCompat.from(context).notify(notificationId, notification)
            wakeScreenForAlert()
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun wakeScreenForAlert() {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isInteractive) {
            return
        }
        val wakeLock = powerManager.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "$TAG:connection-alert",
        )
        // Only reveal the lock-screen notification; never keep the display awake.
        wakeLock.acquire(SCREEN_WAKE_MILLIS)
    }

    private fun ensureChannel(name: String, description: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_EVENT)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                name,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                this.description = description
                setSound(Settings.System.DEFAULT_NOTIFICATION_URI, audioAttributes)
                enableVibration(true)
                setVibrationPattern(VIBRATION_PATTERN)
                enableLights(true)
                lightColor = BRAND_BLUE
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
        )
    }

    private fun removeObsoletePhoneAccounts() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        for ((serviceClass, accountId) in OBSOLETE_PHONE_ACCOUNTS) {
            try {
                telecom.unregisterPhoneAccount(
                    PhoneAccountHandle(
                        ComponentName(context.packageName, serviceClass),
                        accountId,
                    ),
                )
            } catch (_: RuntimeException) {
                // Upgrade cleanup is best-effort and never blocks notifications.
            }
        }
    }

    private fun deviceAvatar(platform: String): Bitmap {
        val bitmap = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = BRAND_BLUE
            style = Paint.Style.FILL
        }
        canvas.drawCircle(64f, 64f, 60f, paint)
        paint.apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            strokeWidth = 8f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }

        when (platform.lowercase()) {
            "android", "ios" -> {
                canvas.drawRoundRect(RectF(43f, 25f, 85f, 103f), 8f, 8f, paint)
                canvas.drawCircle(64f, 91f, 2f, paint)
            }
            "macos", "windows", "linux" -> {
                canvas.drawRoundRect(RectF(27f, 31f, 101f, 82f), 7f, 7f, paint)
                canvas.drawLine(22f, 96f, 106f, 96f, paint)
            }
            else -> {
                paint.apply {
                    style = Paint.Style.FILL
                    textAlign = Paint.Align.CENTER
                    textSize = 54f
                    typeface = Typeface.DEFAULT_BOLD
                }
                canvas.drawText("W", 64f, 83f, paint)
            }
        }
        return bitmap
    }

    private fun actionPendingIntent(
        notificationId: Int,
        requestOffset: Int,
        actionId: String,
        payload: String,
        showsUserInterface: Boolean,
    ): PendingIntent {
        val requestCode = notificationId * 4 + requestOffset
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        if (showsUserInterface) {
            val intent = launchIntent().apply {
                action = SELECT_FOREGROUND_NOTIFICATION_ACTION
                data = actionUri(notificationId, actionId)
                putResponseExtras(notificationId, actionId, payload, false)
            }
            return PendingIntent.getActivity(context, requestCode, intent, flags)
        }
        val intent = Intent(context, ActionBroadcastReceiver::class.java).apply {
            action = ActionBroadcastReceiver.ACTION_TAPPED
            data = actionUri(notificationId, actionId)
            putResponseExtras(notificationId, actionId, payload, true)
        }
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }

    private fun contentPendingIntent(notificationId: Int, payload: String): PendingIntent {
        val intent = launchIntent().apply {
            action = SELECT_NOTIFICATION
            data = actionUri(notificationId, "open")
            putExtra(EXTRA_NOTIFICATION_ID, notificationId)
            putExtra(EXTRA_PAYLOAD, payload)
        }
        return PendingIntent.getActivity(
            context,
            notificationId * 4,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun launchIntent(): Intent =
        (context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }

    private fun actionUri(notificationId: Int, actionId: String): Uri =
        Uri.Builder()
            .scheme("whisper")
            .authority("pairing")
            .appendPath(notificationId.toString())
            .appendPath(actionId)
            .build()

    private fun Intent.putResponseExtras(
        notificationId: Int,
        actionId: String,
        payload: String,
        cancelNotification: Boolean,
    ) {
        putExtra(EXTRA_NOTIFICATION_ID, notificationId)
        putExtra(EXTRA_NOTIFICATION_TAG, null as String?)
        putExtra(EXTRA_ACTION_ID, actionId)
        putExtra(EXTRA_CANCEL_NOTIFICATION, cancelNotification)
        putExtra(EXTRA_PAYLOAD, payload)
    }

    companion object {
        const val CHANNEL_ID = "whisper.incoming_connection.v3"
        private const val TAG = "WhisperPairingAlert"
        private const val TIMEOUT_MILLIS = 30_000L
        private const val SCREEN_WAKE_MILLIS = 5_000L
        private const val BRAND_BLUE = 0xFF2563EB.toInt()
        private val VIBRATION_PATTERN = longArrayOf(0L, 160L, 90L, 160L)
        private val OBSOLETE_PHONE_ACCOUNTS = listOf(
            Pair(
                "com.vireen.whisper.PairingConnectionService",
                "whisper_pairing_alerts_v2",
            ),
            Pair(
                "com.vireen.whisper.WhisperConnectionService",
                "whisper_system_connection_requests_v1",
            ),
            Pair(
                "com.vireen.whisper.WhisperConnectionService",
                "whisper_connection_requests",
            ),
        )
        private const val SELECT_NOTIFICATION = "SELECT_NOTIFICATION"
        private const val SELECT_FOREGROUND_NOTIFICATION_ACTION =
            "SELECT_FOREGROUND_NOTIFICATION"
        private const val EXTRA_NOTIFICATION_ID = "notificationId"
        private const val EXTRA_NOTIFICATION_TAG = "notificationTag"
        private const val EXTRA_ACTION_ID = "actionId"
        private const val EXTRA_CANCEL_NOTIFICATION = "cancelNotification"
        private const val EXTRA_PAYLOAD = "payload"
    }
}
