package com.vireen.whisper

import android.app.Activity
import android.app.Application
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Bundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MobileMotionPlugin : FlutterPlugin, ActivityAware, SensorEventListener,
    EventChannel.StreamHandler, Application.ActivityLifecycleCallbacks {
    private lateinit var sensors: SensorManager
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var activity: Activity? = null
    private var sink: EventChannel.EventSink? = null
    private var gravity: FloatArray? = null
    private var gravityTime = 0L

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        sensors = binding.applicationContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        methods = MethodChannel(binding.binaryMessenger, "com.vireen.whisper/mobile_motion")
        events = EventChannel(binding.binaryMessenger, "com.vireen.whisper/mobile_motion/events")
        methods.setMethodCallHandler { call, result ->
            if (call.method == "available") result.success(available()) else result.notImplemented()
        }
        events.setStreamHandler(this)
    }

    private fun available() = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE) != null &&
        sensors.getDefaultSensor(Sensor.TYPE_GRAVITY) != null

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        stop()
        sink = eventSink
        if (!available()) {
            fail("unavailable")
            return
        }
        val gyro = sensors.registerListener(this, sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE), 10_000)
        val grav = sensors.registerListener(this, sensors.getDefaultSensor(Sensor.TYPE_GRAVITY), 10_000)
        if (!gyro || !grav) fail("unavailable")
    }

    override fun onCancel(arguments: Any?) { stop(); sink = null }
    private fun stop() {
        sensors.unregisterListener(this)
        gravity = null
        gravityTime = 0
    }
    private fun fail(code: String) {
        stop()
        sink?.error(code, "Motion capture stopped", null)
        sink = null
    }
    override fun onSensorChanged(event: SensorEvent) {
        if (event.values.take(3).any { !it.isFinite() }) { fail("invalid-sample"); return }
        if (event.sensor.type == Sensor.TYPE_GRAVITY) {
            gravity = event.values.copyOf(3)
            gravityTime = event.timestamp
        } else if (event.sensor.type == Sensor.TYPE_GYROSCOPE) {
            val g = gravity ?: return
            if (event.timestamp - gravityTime > 500_000_000L) { fail("stale-gravity"); return }
            sink?.success(mapOf("micros" to event.timestamp / 1000,
                "gyro" to event.values.take(3).map { it.toDouble() },
                "gravity" to g.map { it.toDouble() }))
        }
    }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activity?.application?.registerActivityLifecycleCallbacks(this)
    }
    override fun onDetachedFromActivity() {
        stop()
        activity?.application?.unregisterActivityLifecycleCallbacks(this)
        activity = null
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
    override fun onActivityPaused(a: Activity) { if (a === activity) stop() }
    override fun onActivityCreated(a: Activity, state: Bundle?) {}
    override fun onActivityStarted(a: Activity) {}
    override fun onActivityResumed(a: Activity) {}
    override fun onActivityStopped(a: Activity) {}
    override fun onActivitySaveInstanceState(a: Activity, state: Bundle) {}
    override fun onActivityDestroyed(a: Activity) {}
}
