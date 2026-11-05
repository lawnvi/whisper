package com.vireen.whisper

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Tells the Flutter side a pairing done in the notification worked. */
internal object AdbSelfStartEvents {
    @Volatile
    var onPaired: (() -> Unit)? = null

    /** False when no Flutter side is there to start the agent. */
    fun paired(context: Context): Boolean {
        AdbSelfStartPrefs.setPaired(context, true)
        val listener = onPaired ?: return false
        listener()
        return true
    }
}

internal object AdbSelfStartPrefs {
    private const val FILE = "window_stream_self_start"
    private const val PAIRED = "paired"
    private const val AUTO_START = "auto_start"

    private fun prefs(context: Context) = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun paired(context: Context) = prefs(context).getBoolean(PAIRED, false)
    fun setPaired(context: Context, value: Boolean) =
        prefs(context).edit().putBoolean(PAIRED, value).apply()

    fun autoStart(context: Context) = prefs(context).getBoolean(AUTO_START, false)
    fun setAutoStart(context: Context, value: Boolean) =
        prefs(context).edit().putBoolean(AUTO_START, value).apply()
}

/**
 * The phone starting whisper-agent by itself over its own Wireless debugging,
 * with no computer. This side pairs, connects and runs what it is given; the
 * launch scripts are the same [AgentLaunch] text a desktop's adb runs.
 *
 * Needs Android 12: an app can only read the TLS value pairing is bound to
 * through `SSLSockets.exportKeyingMaterial` from there on. Below that, a
 * computer with adb starts the agent, as before.
 */
class WindowStreamSelfStartPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var shell: AdbSelfShell? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        AdbSelfStartEvents.onPaired = {
            main.post { channel?.invokeMethod("paired", null) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        AdbSelfStartEvents.onPaired = null
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        worker.execute {
            shell?.close()
            shell = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = context
        if (context == null) {
            result.error("detached", null, null)
            return
        }
        when (call.method) {
            "available" -> result.success(available)
            "status" -> result.success(status(context))
            "autoStart" -> result.success(AdbSelfStartPrefs.autoStart(context))
            "setAutoStart" -> setAutoStart(context, call.argument<Boolean>("on") == true, result)
            "beginPairing" -> {
                val strings = Bundle()
                call.argument<Map<String, String>>("strings")?.forEach { (key, value) ->
                    strings.putString(key, value)
                }
                try {
                    AdbPairingService.begin(context, strings)
                    result.success(true)
                } catch (_: Exception) {
                    // A foreground service may be refused; the page's field still works.
                    result.success(false)
                }
            }
            "finishStarting" -> {
                try {
                    AdbPairingService.finishStarting(context, call.argument<Boolean>("ok") == true)
                } catch (_: Exception) {
                    // The service is gone, and its notification with it.
                }
                result.success(null)
            }
            "cancelPairing" -> {
                AdbPairingService.cancel(context)
                result.success(null)
            }
            "pair" -> background(result) { pair(context, call.argument<String>("code").orEmpty()) }
            "shell" -> background(result) {
                run(context, call.argument<String>("script").orEmpty())
            }
            "push" -> background(result) {
                val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                withShell(context) { it.push(bytes, call.argument<String>("path").orEmpty()) }
                true
            }
            "disconnect" -> background(result) {
                shell?.close()
                shell = null
                true
            }
            "enableWirelessDebugging" -> background(result) { enableWireless(context) }
            "restoreWirelessDebugging" -> {
                setWireless(context, call.argument<Boolean>("on") == true)
                result.success(null)
            }
            "openWirelessDebugging" -> result.success(openWirelessDebugging(context))
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (error: SelfStartFailure) {
                main.post { result.error(error.code, null, null) }
            } catch (_: Exception) {
                main.post { result.error(FAILED, null, null) }
            }
        }
    }

    private fun status(context: Context): Map<String, Any> = mapOf(
        "developerOptions" to (globalInt(context, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED) == 1),
        "wirelessDebugging" to (globalInt(context, ADB_WIFI_ENABLED) == 1),
        "wifi" to onWifi(context),
        "paired" to AdbSelfStartPrefs.paired(context),
        "canToggle" to canToggleWireless(context),
    )

    private fun globalInt(context: Context, name: String) =
        Settings.Global.getInt(context.contentResolver, name, 0)

    private fun onWifi(context: Context): Boolean {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        // Any network, not the default one: a VPN or mobile data may be on top.
        @Suppress("DEPRECATION")
        return manager.allNetworks.any {
            manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    private fun pair(context: Context, code: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            throw SelfStartFailure(FAILED)
        }
        val port = AdbPairingService.pairingPort
            ?: findPort(context, AdbPortFinder.PAIRING)
            ?: throw SelfStartFailure(NO_PAIRING_SERVICE)
        try {
            AdbPairing.pair(AdbIdentity.load(context), port, code)
        } catch (_: AdbPairingRefused) {
            throw SelfStartFailure(WRONG_CODE)
        }
        AdbSelfStartPrefs.setPaired(context, true)
        AdbPairingService.cancel(context)
        return true
    }

    private fun run(context: Context, script: String): String =
        withShell(context) { it.run(script) }

    /** Reuses the open connection; a dead one (Wireless debugging went away) is replaced. */
    private fun <T> withShell(context: Context, work: (AdbSelfShell) -> T): T {
        val open = shell
        if (open != null) {
            try {
                return work(open)
            } catch (_: Exception) {
                open.close()
                shell = null
            }
        }
        val fresh = connect(context)
        shell = fresh
        return work(fresh)
    }

    private fun connect(context: Context): AdbSelfShell {
        if (!AdbSelfStartPrefs.paired(context)) {
            throw SelfStartFailure(NOT_PAIRED)
        }
        if (globalInt(context, ADB_WIFI_ENABLED) != 1) {
            throw SelfStartFailure(WIRELESS_OFF)
        }
        // Just after it is turned on, mDNS may still answer with the last port.
        val deadline = SystemClock.elapsedRealtime() + CONNECT_WAIT_MS
        val dead = mutableSetOf<Int>()
        while (SystemClock.elapsedRealtime() < deadline) {
            val port = findPort(context, AdbPortFinder.CONNECT, dead) ?: continue
            try {
                return AdbSelfShell.connect(AdbIdentity.load(context), port)
            } catch (_: ConnectException) {
                dead += port
            } catch (_: SocketTimeoutException) {
                dead += port
            } catch (_: Exception) {
                // Reached adbd and it won't have this key: authorizations were
                // revoked. The page goes back to the setup steps.
                AdbSelfStartPrefs.setPaired(context, false)
                throw SelfStartFailure(NOT_PAIRED)
            }
        }
        throw SelfStartFailure(WIRELESS_OFF)
    }

    private fun findPort(
        context: Context,
        type: String,
        ignoring: Set<Int> = emptySet(),
    ): Int? {
        val latch = CountDownLatch(1)
        var port: Int? = null
        val finder = AdbPortFinder(context, type)
        finder.start { next ->
            if (next != null && next !in ignoring) {
                port = next
                latch.countDown()
            }
        }
        latch.await(FIND_TIMEOUT_S, TimeUnit.SECONDS)
        finder.stop()
        return port
    }

    /** Turns Wireless debugging on if this app may; true when it was off before. */
    private fun enableWireless(context: Context): Boolean {
        if (globalInt(context, ADB_WIFI_ENABLED) == 1) {
            return false
        }
        if (!canToggleWireless(context) || !onWifi(context)) {
            throw SelfStartFailure(WIRELESS_OFF)
        }
        setWireless(context, true)
        return true
    }

    private fun setWireless(context: Context, on: Boolean) {
        if (canToggleWireless(context)) {
            Settings.Global.putInt(context.contentResolver, ADB_WIFI_ENABLED, if (on) 1 else 0)
        }
    }

    private fun canToggleWireless(context: Context) =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED

    /** Auto start asks the shell, once, for leave to turn Wireless debugging on. */
    private fun setAutoStart(context: Context, on: Boolean, result: MethodChannel.Result) {
        background(result) {
            if (!on) {
                AdbSelfStartPrefs.setAutoStart(context, false)
                return@background false
            }
            if (!canToggleWireless(context)) {
                try {
                    run(
                        context,
                        "pm grant ${context.packageName} ${Manifest.permission.WRITE_SECURE_SETTINGS}",
                    )
                } finally {
                    shell?.close()
                    shell = null
                }
            }
            val granted = canToggleWireless(context)
            AdbSelfStartPrefs.setAutoStart(context, granted)
            granted
        }
    }

    private fun openWirelessDebugging(context: Context): Boolean = try {
        context.startActivity(
            android.content.Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                .putExtra(":settings:fragment_args_key", "toggle_adb_wireless")
                // Starts the system's settings over: otherwise this only brings
                // back the page they were left on, Whisper's app info, say.
                .addFlags(
                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                        android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK,
                ),
        )
        true
    } catch (_: Exception) {
        false
    }

    private class SelfStartFailure(val code: String) : Exception()

    private companion object {
        const val CHANNEL = "com.vireen.whisper/window_stream_self_start"
        const val ADB_WIFI_ENABLED = "adb_wifi_enabled"
        const val FIND_TIMEOUT_S = 5L
        const val CONNECT_WAIT_MS = 20_000L

        // Error codes the page turns into words.
        const val FAILED = "failed"
        const val NOT_PAIRED = "notPaired"
        const val WIRELESS_OFF = "wirelessOff"
        const val NO_PAIRING_SERVICE = "noPairingService"
        const val WRONG_CODE = "wrongCode"

        val available = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    }
}
