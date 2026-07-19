package com.vireen.whisper

import android.app.ForegroundServiceStartNotAllowedException
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class TransferNotificationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.vireen.whisper/transfer_notifications")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "showProgress" -> {
                val intent = TransferForegroundService
                    .buildIntent(context, TransferForegroundService.COMMAND_PROGRESS)
                    .putExtra(TransferForegroundService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_TEXT, call.argument<String>("text") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_PROGRESS, call.argument<Int>("progress") ?: 0)
                    .putExtra(TransferForegroundService.EXTRA_CHANNEL_NAME, call.argument<String>("channelName") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_CHANNEL_DESCRIPTION, call.argument<String>("channelDescription") ?: "")
                startServiceSafely(intent)
                result.success(null)
            }

            "showStatus" -> {
                val intent = TransferForegroundService
                    .buildIntent(context, TransferForegroundService.COMMAND_STATUS)
                    .putExtra(TransferForegroundService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_TEXT, call.argument<String>("text") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_CHANNEL_NAME, call.argument<String>("channelName") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_CHANNEL_DESCRIPTION, call.argument<String>("channelDescription") ?: "")
                startServiceSafely(intent)
                result.success(null)
            }

            "showTerminal" -> {
                val intent = TransferForegroundService
                    .buildIntent(context, TransferForegroundService.COMMAND_TERMINAL)
                    .putExtra(TransferForegroundService.EXTRA_TITLE, call.argument<String>("title") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_TEXT, call.argument<String>("text") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_CHANNEL_NAME, call.argument<String>("channelName") ?: "")
                    .putExtra(TransferForegroundService.EXTRA_CHANNEL_DESCRIPTION, call.argument<String>("channelDescription") ?: "")
                startServiceSafely(intent)
                result.success(null)
            }

            "cancel" -> {
                startServiceSafely(
                    TransferForegroundService.buildIntent(context, TransferForegroundService.COMMAND_CANCEL)
                )
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * app 在后台且无豁免时 startForegroundService 会抛
     * ForegroundServiceStartNotAllowedException(Android 12+)。
     * 此时进程必然还活着(保活服务在跑),丢一条日志静默降级即可,
     * 下一次进度更新(app 回前台后)会自动恢复。
     */
    private fun startServiceSafely(intent: android.content.Intent) {
        try {
            // Deliver directly to an existing FGS. Starting it again from the
            // background can be denied on Android 12+, which left the last
            // visible progress notification stuck at "receiving".
            if (TransferForegroundService.deliverToRunning(intent)) {
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (error: Exception) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                error is ForegroundServiceStartNotAllowedException
            ) {
                NativePrivacyLog.event(
                    NativeLogEvent.transferServiceStartDenied,
                    reason = NativeLogReason.startDenied,
                )
            } else {
                throw error
            }
        }
    }
}
