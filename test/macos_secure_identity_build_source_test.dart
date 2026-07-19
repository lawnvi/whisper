import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all macOS builds avoid interactive Keychain identity access', () {
    final identitySource = File(
      'lib/socket/device_identity.dart',
    ).readAsStringSync();
    final debugEntitlements = File(
      'macos/Runner/DebugProfile.entitlements',
    ).readAsStringSync();
    final releaseEntitlements = File(
      'macos/Runner/Release.entitlements',
    ).readAsStringSync();

    expect(identitySource, contains('if (Platform.isMacOS)'));
    expect(identitySource, isNot(contains('kDebugMode && Platform.isMacOS')));
    expect(
      identitySource,
      contains('return LocalDeviceIdentitySeedStorage();'),
    );
    expect(
      identitySource,
      contains('return SecureDeviceIdentitySeedStorage();'),
    );
    expect(identitySource, contains('usesDataProtectionKeychain: false'));
    expect(
      identitySource,
      contains("accountName: 'com.vireen.whisper.device-identity.v1'"),
    );
    expect(
      identitySource,
      isNot(contains("accountName: 'flutter_secure_storage_service'")),
    );
    expect(debugEntitlements, isNot(contains('keychain-access-groups')));
    expect(releaseEntitlements, isNot(contains('keychain-access-groups')));
  });

  test('macOS privacy manifests are treated as resources', () {
    final podfile = File('macos/Podfile').readAsStringSync();

    expect(podfile, contains('move_privacy_manifests_to_resources'));
    expect(podfile, contains("end_with?('.xcprivacy')"));
    expect(podfile, contains('target.resources_build_phase'));
  });
}
