package com.vireen.whisper

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class LocalNetworkPermissionPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val pendingResults = mutableListOf<MethodChannel.Result>()
    private var pendingPermission: String? = null
    private var requestInFlight = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        detachActivity()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        finishPending(STATUS_UNKNOWN)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val android16CompatTest = call.argument<Boolean>(ARG_COMPAT_TEST) ?: false
        when (call.method) {
            "ensureGranted" -> ensureGranted(android16CompatTest, result)
            "currentStatus" -> result.success(currentStatus(android16CompatTest))
            else -> result.notImplemented()
        }
    }

    private fun ensureGranted(
        android16CompatTest: Boolean,
        result: MethodChannel.Result,
    ) {
        val permission = requiredPermission(android16CompatTest)
        if (permission == null) {
            result.success(STATUS_GRANTED)
            return
        }

        when (permissionStatus(permission)) {
            STATUS_GRANTED -> {
                result.success(STATUS_GRANTED)
                return
            }
            STATUS_RESTRICTED -> {
                result.success(STATUS_RESTRICTED)
                return
            }
        }

        if (requestInFlight) {
            if (pendingPermission == permission) {
                pendingResults.add(result)
            } else {
                result.success(STATUS_UNKNOWN)
            }
            return
        }

        val currentActivity = activity
        if (currentActivity == null) {
            result.success(STATUS_UNKNOWN)
            return
        }

        pendingPermission = permission
        pendingResults.add(result)
        requestInFlight = true
        try {
            ActivityCompat.requestPermissions(
                currentActivity,
                arrayOf(permission),
                REQUEST_CODE,
            )
        } catch (_: SecurityException) {
            finishPending(STATUS_RESTRICTED)
        }
    }

    private fun currentStatus(android16CompatTest: Boolean): String {
        val permission = requiredPermission(android16CompatTest)
            ?: return STATUS_GRANTED
        return permissionStatus(permission)
    }

    private fun requiredPermission(android16CompatTest: Boolean): String? {
        return when {
            Build.VERSION.SDK_INT >= 37 -> ACCESS_LOCAL_NETWORK_PERMISSION
            Build.VERSION.SDK_INT == 36 && android16CompatTest ->
                Manifest.permission.NEARBY_WIFI_DEVICES
            else -> null
        }
    }

    private fun permissionStatus(permission: String): String {
        return try {
            if (ContextCompat.checkSelfPermission(context, permission) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                STATUS_GRANTED
            } else {
                STATUS_DENIED
            }
        } catch (_: SecurityException) {
            STATUS_RESTRICTED
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) {
            return false
        }
        val permission = pendingPermission ?: return true
        val permissionIndex = permissions.indexOf(permission)
        val granted = permissionIndex >= 0 &&
            grantResults.getOrNull(permissionIndex) == PackageManager.PERMISSION_GRANTED
        finishPending(if (granted) STATUS_GRANTED else STATUS_DENIED)
        return true
    }

    private fun finishPending(status: String) {
        val results = pendingResults.toList()
        pendingResults.clear()
        pendingPermission = null
        requestInFlight = false
        results.forEach { it.success(status) }
    }

    private companion object {
        const val CHANNEL_NAME = "com.vireen.whisper/local_network_permission"
        const val ARG_COMPAT_TEST = "android16CompatTest"
        const val ACCESS_LOCAL_NETWORK_PERMISSION =
            "android.permission.ACCESS_LOCAL_NETWORK"
        const val REQUEST_CODE = 8471
        const val STATUS_GRANTED = "granted"
        const val STATUS_DENIED = "denied"
        const val STATUS_RESTRICTED = "restricted"
        const val STATUS_UNKNOWN = "unknown"
    }
}
