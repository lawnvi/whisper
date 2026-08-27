package com.vireen.whisper

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class AndroidPrivacyPermissionPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var notificationResult: MethodChannel.Result? = null
    private var installedAppsResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        finishPending(false)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity(finishRequests = false)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity(finishRequests = true)
    }

    private fun detachActivity(finishRequests: Boolean) {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        if (finishRequests) {
            finishPending(false)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestNotificationListener" -> requestNotificationListener(result)
            "requestInstalledApps" -> requestInstalledApps(result)
            else -> result.notImplemented()
        }
    }

    private fun requestNotificationListener(result: MethodChannel.Result) {
        if (hasNotificationListenerPermission()) {
            result.success(true)
            return
        }
        val currentActivity = activity
        if (currentActivity == null || notificationResult != null) {
            result.success(false)
            return
        }
        notificationResult = result
        val component = ComponentName(
            binding.applicationContext,
            "im.zoe.labs.flutter_notification_listener.NotificationsHandlerService",
        )
        val detailIntent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
            .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, component.flattenToString())
        try {
            currentActivity.startActivityForResult(detailIntent, NOTIFICATION_LISTENER_REQUEST)
        } catch (_: Exception) {
            try {
                currentActivity.startActivityForResult(
                    Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS),
                    NOTIFICATION_LISTENER_REQUEST,
                )
            } catch (_: Exception) {
                notificationResult = null
                result.success(false)
            }
        }
    }

    private fun hasNotificationListenerPermission(): Boolean {
        return NotificationManagerCompat.getEnabledListenerPackages(binding.applicationContext)
            .contains(binding.applicationContext.packageName)
    }

    private fun requestInstalledApps(result: MethodChannel.Result) {
        if (!supportsMiuiInstalledAppsPermission()) {
            result.success(true)
            return
        }
        if (ContextCompat.checkSelfPermission(
                binding.applicationContext,
                INSTALLED_APPS_PERMISSION,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        val currentActivity = activity
        if (currentActivity == null || installedAppsResult != null) {
            result.success(false)
            return
        }
        installedAppsResult = result
        ActivityCompat.requestPermissions(
            currentActivity,
            arrayOf(INSTALLED_APPS_PERMISSION),
            INSTALLED_APPS_REQUEST,
        )
    }

    private fun supportsMiuiInstalledAppsPermission(): Boolean {
        return try {
            binding.applicationContext.packageManager
                .getPermissionInfo(INSTALLED_APPS_PERMISSION, 0)
                .packageName == MIUI_PERMISSION_CONTROLLER
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != NOTIFICATION_LISTENER_REQUEST) {
            return false
        }
        notificationResult?.success(hasNotificationListenerPermission())
        notificationResult = null
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != INSTALLED_APPS_REQUEST) {
            return false
        }
        val granted = permissions.indexOf(INSTALLED_APPS_PERMISSION).let { index ->
            index >= 0 && grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
        }
        installedAppsResult?.success(granted)
        installedAppsResult = null
        return true
    }

    private fun finishPending(granted: Boolean) {
        notificationResult?.success(granted)
        notificationResult = null
        installedAppsResult?.success(granted)
        installedAppsResult = null
    }

    private companion object {
        const val CHANNEL_NAME = "whisper/android_privacy_permissions"
        const val INSTALLED_APPS_PERMISSION = "com.android.permission.GET_INSTALLED_APPS"
        const val MIUI_PERMISSION_CONTROLLER = "com.lbe.security.miui"
        const val NOTIFICATION_LISTENER_REQUEST = 7401
        const val INSTALLED_APPS_REQUEST = 7402
    }
}
