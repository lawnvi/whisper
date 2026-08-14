package com.vireen.whisper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
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
        WhisperConnectionService.ensurePhoneAccount(context)
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
            "showIncoming" -> result.success(showIncoming(call))
            "dismissIncoming" -> {
                val notificationId = call.argument<Int>("notificationId")
                if (notificationId == null) {
                    result.success(false)
                } else {
                    WhisperConnectionService.dismissIncoming(notificationId)
                    result.success(true)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun showIncoming(call: MethodCall): Boolean {
        val notificationId = call.argument<Int>("notificationId") ?: return false
        val peerId = call.argument<String>("peerId")?.takeIf { it.isNotBlank() }
            ?: return false
        val deviceName = call.argument<String>("deviceName")?.takeIf { it.isNotBlank() }
            ?: return false
        val pairingCode = call.argument<String>("pairingCode")?.takeIf { it.isNotBlank() }
            ?: return false
        val verificationText = call.argument<String>("verificationText") ?: pairingCode
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
        val caller = Person.Builder()
            .setName(deviceName)
            .setKey(peerId)
            .setImportant(true)
            .build()
        val style = NotificationCompat.CallStyle.forIncomingCall(
            caller,
            rejectIntent,
            answerIntent,
        )
            .setVerificationText(verificationText)
            .setDeclineButtonColorHint(Color.rgb(220, 38, 38))
            .setAnswerButtonColorHint(Color.rgb(22, 163, 74))
        val openIntent = contentPendingIntent(notificationId, payload)
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_whisper)
            .setContentTitle(deviceName)
            .setContentText(verificationText)
            .setContentIntent(openIntent)
            .setStyle(style)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setColor(Color.rgb(22, 163, 74))
            .setDefaults(Notification.DEFAULT_ALL)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setTimeoutAfter(TIMEOUT_MILLIS)
        if (canUseFullScreenIntent()) {
            builder.setFullScreenIntent(openIntent, true)
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            builder.setColorized(true)
        }
        val notification = builder.build()

        WhisperConnectionService.reportIncoming(
            context = context,
            notificationId = notificationId,
            peerId = peerId,
            deviceName = deviceName,
            answerIntent = answerIntent,
            rejectIntent = rejectIntent,
        )
        NotificationManagerCompat.from(context).notify(notificationId, notification)
        return true
    }

    private fun ensureChannel(name: String, description: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                name,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                this.description = description
                enableVibration(true)
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
        )
    }

    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return true
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager
        return manager.canUseFullScreenIntent()
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
        const val CHANNEL_ID = "whisper.incoming_connection.v1"
        private const val TIMEOUT_MILLIS = 30_000L
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
