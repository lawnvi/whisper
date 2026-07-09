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
    private val state = LocalNetworkPermissionRequestState<MethodChannel.Result>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        detachActivity(permanent = true)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity(permanent = false)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity(permanent = true)
    }

    private fun detachActivity(permanent: Boolean) {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        finishPending(
            state.onActivityDetached(permanent = permanent),
            NativeLocalNetworkPermissionStatus.UNKNOWN,
        )
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
            result.success(NativeLocalNetworkPermissionStatus.GRANTED.wireValue)
            return
        }

        when (permissionStatus(permission)) {
            NativeLocalNetworkPermissionStatus.GRANTED -> {
                result.success(NativeLocalNetworkPermissionStatus.GRANTED.wireValue)
                return
            }
            NativeLocalNetworkPermissionStatus.RESTRICTED -> {
                result.success(NativeLocalNetworkPermissionStatus.RESTRICTED.wireValue)
                return
            }
            else -> Unit
        }

        val currentActivity = activity
        if (!state.hasPendingRequest && currentActivity == null) {
            result.success(NativeLocalNetworkPermissionStatus.UNKNOWN.wireValue)
            return
        }

        val enqueue = state.enqueue(permission, result)
        when (enqueue.disposition) {
            PermissionRequestDisposition.MERGED -> return
            PermissionRequestDisposition.CONFLICT -> {
                result.success(NativeLocalNetworkPermissionStatus.UNKNOWN.wireValue)
                return
            }
            PermissionRequestDisposition.START -> Unit
        }
        val requestCode = enqueue.requestCode!!
        val requestActivity = currentActivity
        if (requestActivity == null) {
            finishPending(
                state.complete(requestCode),
                NativeLocalNetworkPermissionStatus.UNKNOWN,
            )
            return
        }
        try {
            ActivityCompat.requestPermissions(
                requestActivity,
                arrayOf(permission),
                requestCode,
            )
        } catch (_: SecurityException) {
            finishPending(
                state.complete(requestCode),
                NativeLocalNetworkPermissionStatus.RESTRICTED,
            )
        }
    }

    private fun currentStatus(android16CompatTest: Boolean): String {
        val permission = requiredPermission(android16CompatTest)
            ?: return NativeLocalNetworkPermissionStatus.GRANTED.wireValue
        return permissionStatus(permission).wireValue
    }

    private fun requiredPermission(android16CompatTest: Boolean): String? {
        return when {
            Build.VERSION.SDK_INT >= 37 -> ACCESS_LOCAL_NETWORK_PERMISSION
            Build.VERSION.SDK_INT == 36 && android16CompatTest ->
                Manifest.permission.NEARBY_WIFI_DEVICES
            else -> null
        }
    }

    private fun permissionStatus(permission: String): NativeLocalNetworkPermissionStatus {
        return queryNativePermissionStatus(
            isGranted = {
                ContextCompat.checkSelfPermission(context, permission) ==
                    PackageManager.PERMISSION_GRANTED
            },
            isRevokedByPolicy = {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                    context.packageManager.isPermissionRevokedByPolicy(permission, context.packageName)
            },
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        val completion = state.complete(requestCode, permissions.asList()) ?: return false
        val permissionIndex = permissions.indexOf(completion.permission)
        val granted = permissionIndex >= 0 &&
            grantResults.getOrNull(permissionIndex) == PackageManager.PERMISSION_GRANTED
        val status = if (granted) {
            NativeLocalNetworkPermissionStatus.GRANTED
        } else {
            permissionStatus(completion.permission)
        }
        finishPending(completion, status)
        return true
    }

    private fun finishPending(
        completion: PendingPermissionCompletion<MethodChannel.Result>?,
        status: NativeLocalNetworkPermissionStatus,
    ) {
        completion?.callbacks?.forEach { it.success(status.wireValue) }
    }

    private companion object {
        const val CHANNEL_NAME = "com.vireen.whisper/local_network_permission"
        const val ARG_COMPAT_TEST = "android16CompatTest"
        const val ACCESS_LOCAL_NETWORK_PERMISSION =
            "android.permission.ACCESS_LOCAL_NETWORK"
    }
}
