package com.vireen.whisper

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Match the control page's fade instead of rotating a stale keyboard frame.
        window.attributes = window.attributes.apply {
            rotationAnimation = WindowManager.LayoutParams.ROTATION_ANIMATION_CROSSFADE
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        flutterEngine.plugins.add(DirPlugin())
        flutterEngine.plugins.add(BackgroundKeepAlivePlugin())
        flutterEngine.plugins.add(AudioSharePlugin())
        flutterEngine.plugins.add(MobileMotionPlugin())
        flutterEngine.plugins.add(AndroidDocumentPickerPlugin())
        flutterEngine.plugins.add(AndroidSystemSharePlugin())
        flutterEngine.plugins.add(TransferNotificationPlugin())
        flutterEngine.plugins.add(ConnectionRequestNotificationPlugin())
        flutterEngine.plugins.add(LocalNetworkPermissionPlugin())
        flutterEngine.plugins.add(AndroidPrivacyPermissionPlugin())
    }
}
