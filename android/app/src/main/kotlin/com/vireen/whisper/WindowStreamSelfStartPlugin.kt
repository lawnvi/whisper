package com.vireen.whisper

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The phone starting whisper-agent by itself over its own Wireless
 * debugging — no computer. The full flow is adb pairing (SPAKE2 over
 * TLS 1.3, Android 11+) with the 6-digit code, then `adb connect` and
 * running the launch script.
 *
 * Pairing needs a SPAKE2 implementation. The maintained libraries pull in
 * BouncyCastle (~8 MB), which breaks the app's "modest APK growth" rule, so
 * no pairing crypto is bundled in this build and [available] is false: the
 * page then guides the user to start the service from a computer with
 * Whisper once (the desktop-assisted start), after which every computer —
 * adb or not — reaches this phone through the agent. When a slim SPAKE2
 * (platform TLS `SSLSockets.exportKeyingMaterial` + a small SPAKE2 port +
 * the AOSP PairingPacket framing) is added here, this plugin's
 * `pairAndStart`/`start` become real and [available] returns true.
 */
class WindowStreamSelfStartPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(SELF_START_AVAILABLE)
            "autoStart" -> result.success(false)
            "setAutoStart" -> result.success(false)
            "pairAndStart" -> result.success(false)
            "start" -> result.success(false)
            else -> result.notImplemented()
        }
    }

    private companion object {
        const val CHANNEL = "com.vireen.whisper/window_stream_self_start"

        /** True once a bundled pairing client lands (see the class doc). */
        const val SELF_START_AVAILABLE = false
    }
}
