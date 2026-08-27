import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const pluginPath =
      'android/app/src/main/kotlin/com/vireen/whisper/LocalNetworkPermissionPlugin.kt';

  test(
    'Android target 36 relies on implicit LAN access without nearby prompts',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();

      expect(manifest, contains('android.permission.INTERNET'));
      expect(manifest, contains('android.permission.ACCESS_NETWORK_STATE'));
      expect(manifest, contains('android.permission.ACCESS_WIFI_STATE'));
      expect(
        manifest,
        contains('android.permission.CHANGE_WIFI_MULTICAST_STATE'),
      );
      expect(
        manifest,
        isNot(contains('android.permission.NEARBY_WIFI_DEVICES')),
      );
      expect(
        manifest,
        isNot(contains('android.permission.ACCESS_LOCAL_NETWORK')),
      );
      expect(
        manifest,
        isNot(contains('android.permission.ACCESS_FINE_LOCATION')),
      );
      expect(
        manifest,
        isNot(contains('android.permission.ACCESS_COARSE_LOCATION')),
      );
    },
  );

  test('Android manifest gates app-list access and excludes unused access', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('com.android.permission.GET_INSTALLED_APPS'));
    expect(manifest, contains('android.permission.QUERY_ALL_PACKAGES'));
    final permissionPlugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/AndroidPrivacyPermissionPlugin.kt',
    ).readAsStringSync();
    expect(permissionPlugin, contains('requestInstalledApps'));
    expect(permissionPlugin, contains('com.lbe.security.miui'));
    expect(permissionPlugin, contains('ActivityCompat.requestPermissions'));
    for (final unusedPermission in <String>[
      'android.permission.SET_WALLPAPER',
      'android.permission.SET_WALLPAPER_HINTS',
      'android.permission.USE_FULL_SCREEN_INTENT',
    ]) {
      expect(manifest, isNot(contains(unusedPermission)));
    }
  });

  test('Android permission plugin gates runtime access on target API 37', () {
    final plugin = File(pluginPath).readAsStringSync();
    final requestState = File(
      'android/app/src/main/kotlin/com/vireen/whisper/LocalNetworkPermissionRequestState.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt',
    ).readAsStringSync();

    expect(plugin, contains('ActivityAware'));
    expect(plugin, contains('RequestPermissionsResultListener'));
    expect(plugin, contains('Application.ActivityLifecycleCallbacks'));
    expect(plugin, contains('EventChannel.StreamHandler'));
    expect(plugin, contains('registerActivityLifecycleCallbacks(this)'));
    expect(plugin, contains('unregisterActivityLifecycleCallbacks(this)'));
    expect(
      plugin,
      contains('override fun onActivityResumed(activity: Activity)'),
    );
    expect(plugin, contains('emitCurrentPermissionStatus()'));
    expect(requestState, contains('sdkInt >= 37 && targetSdkInt >= 37'));
    expect(plugin, contains('android.permission.ACCESS_LOCAL_NETWORK'));
    expect(plugin, isNot(contains('Manifest.permission.NEARBY_WIFI_DEVICES')));
    expect(
      plugin,
      contains('targetSdkInt = context.applicationInfo.targetSdkVersion'),
    );
    expect(plugin, contains('LocalNetworkPermissionRequestState'));
    expect(plugin, contains('state.enqueue(permission, result)'));
    expect(plugin, contains('state.hasPendingRequest'));
    expect(plugin, contains('SecurityException'));
    expect(plugin, contains('finishPending'));
    expect(plugin, contains('detachActivity(permanent = false)'));
    expect(plugin, contains('detachActivity(permanent = true)'));
    expect(plugin, contains('state.onActivityPermanentlyDetached()'));
    expect(
      plugin,
      contains(
        'state.complete(requestCode, permissions.asList()) ?: return false',
      ),
    );
    expect(
      plugin,
      contains('isPermissionRevokedByPolicy(permission, context.packageName)'),
    );
    expect(activity, contains('LocalNetworkPermissionPlugin()'));
    expect(plugin, contains('ConnectivityManager'));
    expect(plugin, contains('NetworkCapabilities.TRANSPORT_WIFI'));
    expect(plugin, contains('currentLanAddress'));
    expect(plugin, contains('selectLanIpv4Address'));
    expect(plugin, contains('isLinkLocalLanIpv4'));
    expect(plugin, contains('isUsableUnicastIpv4'));
    expect(plugin, contains('octets[0] == 169 && octets[1] == 254'));
  });

  test('iOS ATS is a dictionary and Bonjour declares the Whisper service', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final atsIndex = plist.indexOf('<key>NSAppTransportSecurity</key>');
    final bonjourIndex = plist.indexOf('<key>NSBonjourServices</key>');

    expect(atsIndex, greaterThanOrEqualTo(0));
    expect(plist.substring(atsIndex, bonjourIndex), contains('<dict>'));
    expect(
      plist.substring(atsIndex, bonjourIndex),
      contains('<key>NSAllowsLocalNetworking</key>'),
    );
    expect(plist, contains('<key>NSLocalNetworkUsageDescription</key>'));
    expect(plist, contains('<string>_whisper._tcp</string>'));
    expect(plist, isNot(contains('NSLocationWhenInUseUsageDescription')));
    expect(
      plist,
      isNot(contains('NSLocationAlwaysAndWhenInUseUsageDescription')),
    );

    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(appDelegate, contains('NWBrowser'));
    expect(
      appDelegate,
      contains('.bonjour(type: "_whisper._tcp", domain: "local.")'),
    );
    expect(
      appDelegate,
      contains('UIApplication.shared.applicationState == .active'),
    );
    expect(appDelegate, contains('kDNSServiceErr_PolicyDenied'));
    expect(appDelegate, contains('case "currentStatus":'));
    expect(appDelegate, contains('result("unknown")'));
    expect(appDelegate, contains('"unavailable"'));
    expect(appDelegate, contains('"retryable"'));

    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    expect(deviceList, isNot(contains('Permission.location')));
    expect(
      deviceList,
      contains('Future<void> _requestLocalNetworkPermission()'),
    );
    expect(deviceList, contains('await LocalNetworkPermission().ensureGranted()'));
    expect(deviceList, contains('await _localNetworkPermissionBootstrap'));

    final entitlements = File(
      'ios/Runner/Runner.entitlements',
    ).readAsStringSync();
    expect(
      entitlements,
      isNot(contains('com.apple.developer.networking.wifi-info')),
    );
    expect(
      entitlements,
      isNot(contains('com.apple.developer.networking.multicast')),
      reason: 'A fixed Bonjour service does not require multicast entitlement',
    );

    if (Platform.isMacOS) {
      final lint = Process.runSync('plutil', <String>[
        '-lint',
        'ios/Runner/Info.plist',
      ]);
      expect(lint.exitCode, 0, reason: '${lint.stdout}${lint.stderr}');
    }
  });

  test('macOS declares honest local-network and Bonjour usage', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<key>NSLocalNetworkUsageDescription</key>'));
    expect(plist, contains('<key>NSBonjourServices</key>'));
    expect(plist, contains('<string>_whisper._tcp</string>'));
    expect(plist.toLowerCase(), contains('local network'));

    for (final path in <String>[
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      final entitlements = File(path).readAsStringSync();
      expect(entitlements, contains('com.apple.security.network.server'));
      expect(entitlements, contains('com.apple.security.network.client'));
    }

    if (Platform.isMacOS) {
      final lint = Process.runSync('plutil', <String>[
        '-lint',
        'macos/Runner/Info.plist',
      ]);
      expect(lint.exitCode, 0, reason: '${lint.stdout}${lint.stderr}');
    }
  });
}
