import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const pluginPath =
      'android/app/src/main/kotlin/com/vireen/whisper/LocalNetworkPermissionPlugin.kt';

  test('Android manifest declares LAN permissions without location expansion',
      () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(manifest, contains('android.permission.INTERNET'));
    expect(manifest, contains('android.permission.ACCESS_NETWORK_STATE'));
    expect(manifest, contains('android.permission.ACCESS_WIFI_STATE'));
    expect(
        manifest, contains('android.permission.CHANGE_WIFI_MULTICAST_STATE'));
    expect(manifest, contains('android.permission.NEARBY_WIFI_DEVICES'));
    expect(manifest, contains('android:maxSdkVersion="36"'));
    expect(
        manifest, contains('android:usesPermissionFlags="neverForLocation"'));
    expect(manifest, contains('android.permission.ACCESS_LOCAL_NETWORK'));
    expect(
        manifest, isNot(contains('android.permission.ACCESS_FINE_LOCATION')));
    expect(
        manifest, isNot(contains('android.permission.ACCESS_COARSE_LOCATION')));
  });

  test('Android permission plugin covers normal, compat, and API 37 paths', () {
    final plugin = File(pluginPath).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt',
    ).readAsStringSync();

    expect(plugin, contains('ActivityAware'));
    expect(plugin, contains('RequestPermissionsResultListener'));
    expect(plugin, contains('android16CompatTest'));
    expect(plugin, contains('Build.VERSION.SDK_INT >= 37'));
    expect(plugin, contains('Build.VERSION.SDK_INT == 36'));
    expect(plugin, contains('android.permission.ACCESS_LOCAL_NETWORK'));
    expect(plugin, contains('Manifest.permission.NEARBY_WIFI_DEVICES'));
    expect(plugin, contains('LocalNetworkPermissionRequestState'));
    expect(plugin, contains('state.enqueue(permission, result)'));
    expect(plugin, contains('state.hasPendingRequest'));
    expect(plugin, contains('SecurityException'));
    expect(plugin, contains('finishPending'));
    expect(
      plugin,
      contains('detachActivity(permanent = false)'),
    );
    expect(plugin, contains('detachActivity(permanent = true)'));
    expect(
      plugin,
      contains('state.onActivityDetached(permanent = permanent)'),
    );
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
  });

  test('iOS ATS is a dictionary and Bonjour declares the Whisper service', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final atsIndex = plist.indexOf('<key>NSAppTransportSecurity</key>');
    final bonjourIndex = plist.indexOf('<key>NSBonjourServices</key>');

    expect(atsIndex, greaterThanOrEqualTo(0));
    expect(
      plist.substring(atsIndex, bonjourIndex),
      contains('<dict>'),
    );
    expect(
      plist.substring(atsIndex, bonjourIndex),
      contains('<key>NSAllowsLocalNetworking</key>'),
    );
    expect(plist, contains('<key>NSLocalNetworkUsageDescription</key>'));
    expect(plist, contains('<string>_whisper._tcp</string>'));

    if (Platform.isMacOS) {
      final lint =
          Process.runSync('plutil', <String>['-lint', 'ios/Runner/Info.plist']);
      expect(lint.exitCode, 0, reason: '${lint.stdout}${lint.stderr}');
    }
  });

  test('macOS declares honest local-network and Bonjour usage', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<key>NSLocalNetworkUsageDescription</key>'));
    expect(plist, contains('<key>NSBonjourServices</key>'));
    expect(plist, contains('<string>_whisper._tcp</string>'));
    expect(plist.toLowerCase(), contains('local network'));

    if (Platform.isMacOS) {
      final lint = Process.runSync(
        'plutil',
        <String>['-lint', 'macos/Runner/Info.plist'],
      );
      expect(lint.exitCode, 0, reason: '${lint.stdout}${lint.stderr}');
    }
  });
}
