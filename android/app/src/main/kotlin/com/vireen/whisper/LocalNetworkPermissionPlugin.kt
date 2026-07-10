package com.vireen.whisper

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.PluginRegistry

class LocalNetworkPermissionPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    Application.ActivityLifecycleCallbacks,
    EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var application: Application? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var observedPermission: String? = null
    private val state = LocalNetworkPermissionRequestState<MethodChannel.Result>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL_NAME).also {
            it.setStreamHandler(this)
        }
        application = binding.applicationContext as? Application
        application?.registerActivityLifecycleCallbacks(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        application?.unregisterActivityLifecycleCallbacks(this)
        application = null
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
        if (permanent) {
            state.onActivityPermanentlyDetached().forEach { completion ->
                finishPending(
                    completion,
                    NativeLocalNetworkPermissionStatus.UNKNOWN,
                )
            }
        } else {
            state.onActivityDetached(permanent = false)
        }
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
        val permission = observeRequiredPermission(android16CompatTest)
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
            PermissionRequestDisposition.QUEUED -> return
            PermissionRequestDisposition.START -> Unit
        }
        requestPermission(
            PendingPermissionRequest(
                permission = permission,
                requestCode = enqueue.requestCode!!,
            ),
            currentActivity,
        )
    }

    private fun requestPermission(
        request: PendingPermissionRequest,
        requestActivity: Activity? = activity,
    ) {
        if (requestActivity == null) {
            finishPending(
                state.complete(request.requestCode),
                NativeLocalNetworkPermissionStatus.UNKNOWN,
            )
            return
        }
        try {
            ActivityCompat.requestPermissions(
                requestActivity,
                arrayOf(request.permission),
                request.requestCode,
            )
        } catch (_: SecurityException) {
            finishPending(
                state.complete(request.requestCode),
                permissionStatus(request.permission),
            )
        }
    }

    private fun currentStatus(android16CompatTest: Boolean): String {
        val permission = observeRequiredPermission(android16CompatTest)
            ?: return NativeLocalNetworkPermissionStatus.GRANTED.wireValue
        return permissionStatus(permission).wireValue
    }

    private fun observeRequiredPermission(android16CompatTest: Boolean): String? {
        return requiredPermission(android16CompatTest)?.also { permission ->
            observedPermission = permission
        }
    }

    private fun requiredPermission(android16CompatTest: Boolean): String? {
        return requiredLocalNetworkPermission(
            sdkInt = Build.VERSION.SDK_INT,
            android16CompatTest = android16CompatTest,
            nearbyWifiDevicesPermission = Manifest.permission.NEARBY_WIFI_DEVICES,
            accessLocalNetworkPermission = ACCESS_LOCAL_NETWORK_PERMISSION,
        )
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
        if (completion == null) {
            return
        }
        completion.callbacks.forEach { it.success(status.wireValue) }
        eventSink?.success(status.wireValue)
        completion.nextRequest?.let(::requestPermission)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        emitCurrentPermissionStatus()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emitCurrentPermissionStatus() {
        val permission = observedPermission ?: requiredPermission(android16CompatTest = false)
        val status = if (permission == null) {
            NativeLocalNetworkPermissionStatus.GRANTED
        } else {
            permissionStatus(permission)
        }
        eventSink?.success(status.wireValue)
    }

    override fun onActivityResumed(activity: Activity) {
        if (activity === this.activity) {
            emitCurrentPermissionStatus()
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    override fun onActivityDestroyed(activity: Activity) = Unit

    private companion object {
        const val CHANNEL_NAME = "com.vireen.whisper/local_network_permission"
        const val EVENT_CHANNEL_NAME =
            "com.vireen.whisper/local_network_permission/events"
        const val ARG_COMPAT_TEST = "android16CompatTest"
        const val ACCESS_LOCAL_NETWORK_PERMISSION =
            "android.permission.ACCESS_LOCAL_NETWORK"
    }
}
