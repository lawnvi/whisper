package com.vireen.whisper

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Lets the Flutter side read the persistent agent's link
 * ([WindowStreamAgentLink]) and hears about new ones as the agent pushes
 * them. Attached by [WindowStreamPhonePlugin].
 */
class WindowStreamAgentPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private val listener: (Map<String, Any>) -> Unit = { link ->
        main.post { channel?.invokeMethod("linked", link) }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        WindowStreamAgentLink.addListener(listener)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        WindowStreamAgentLink.removeListener(listener)
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = context
        if (context == null) {
            result.error("detached", null, null)
            return
        }
        when (call.method) {
            "link" -> result.success(WindowStreamAgentLink.load(context))
            "clearLink" -> {
                WindowStreamAgentLink.clear(context)
                result.success(null)
            }
            "openDeviceInfo" ->
                result.success(open(context, Settings.ACTION_DEVICE_INFO_SETTINGS))
            "openDeveloperOptions" ->
                result.success(open(context, Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
            else -> result.notImplemented()
        }
    }

    /** Opens a system settings screen; falls back to app details if missing. */
    private fun open(context: Context, action: String): Boolean = try {
        context.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: Exception) {
        try {
            context.startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", context.packageName, null),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    private companion object {
        const val CHANNEL = "com.vireen.whisper/window_stream_agent"
    }
}
