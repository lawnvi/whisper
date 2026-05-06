import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification app picker includes known SMS packages from system apps',
      () {
    final source = File('lib/page/appList.dart').readAsStringSync();

    expect(source, contains('isVerificationCodeNotificationPackage'));
    expect(
      RegExp(
        r'InstalledApps\.getInstalledApps\([\s\S]*?excludeSystemApps:\s*false',
      ).hasMatch(source),
      isTrue,
    );
  });
}
