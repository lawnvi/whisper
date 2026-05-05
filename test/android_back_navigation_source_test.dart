import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('android opts out of predictive back preview animations', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final mainActivity = RegExp(
      r'<activity[\s\S]*?android:name="\.MainActivity"[\s\S]*?>',
    ).firstMatch(manifest)!.group(0)!;

    expect(
      mainActivity,
      contains('android:enableOnBackInvokedCallback="false"'),
    );
  });

  test('android page transitions do not use predictive back builder', () {
    final theme = File('lib/theme/app_theme.dart').readAsStringSync();

    expect(
      theme,
      contains('TargetPlatform.android: ZoomPageTransitionsBuilder()'),
    );
    expect(theme, isNot(contains('PredictiveBackPageTransitionsBuilder')));
  });
}
