import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/helper/local.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
    SharedPreferences.setMockInitialValues(<String, Object>{
      '_uuid': 'local-device',
      '_name': 'Local device',
      '_port': 10002,
      '_is_server': false,
      '_clipboard': true,
      '_no_auth': true,
      '_password': '',
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('local device never advertises automatic approval from legacy storage',
      () async {
    final device = await LocalSetting().instance();
    final preferences = await SharedPreferences.getInstance();

    expect(device.auth, isFalse);
    expect(preferences.getBool('_no_auth'), isTrue);
  });

  test('local settings no longer expose or read automatic approval', () {
    final source = File('lib/helper/local.dart').readAsStringSync();

    expect(source, isNot(contains('_noAuth')));
    expect(source, isNot(contains('_no_auth')));
    expect(source, isNot(contains('updateNoAuth')));
    expect(source, isNot(contains('autoApproveNewDevices')));
    expect(source, contains('auth: false'));
  });
}
