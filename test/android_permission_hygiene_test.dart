import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android manifest keeps only permissions used by app features', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    for (final permission in <String>[
      'android.permission.READ_CLIPBOARD',
      'android.permission.WRITE_CLIPBOARD',
      'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
      'android.permission.READ_PHONE_NUMBERS',
      'android.permission.READ_PHONE_STATE',
    ]) {
      expect(manifest, isNot(contains(permission)));
    }

    for (final pluginPermission in <String>[
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.READ_MEDIA_VIDEO',
      'android.permission.READ_MEDIA_AUDIO',
      'android.permission.REQUEST_DELETE_PACKAGES',
      'android.permission.RECEIVE_BOOT_COMPLETED',
    ]) {
      expect(
        manifest,
        contains('android:name="$pluginPermission" tools:node="remove"'),
      );
    }

    expect(manifest, isNot(contains('ScheduledNotificationReceiver')));
    expect(manifest, isNot(contains('ScheduledNotificationBootReceiver')));
    expect(
      manifest,
      contains('android.permission.QUERY_ALL_PACKAGES'),
      reason: 'notification forwarding lets the user choose any installed app',
    );
    expect(
      manifest,
      contains('android.permission.MANAGE_EXTERNAL_STORAGE'),
      reason: 'received files currently use the public Download directory',
    );
    for (final phonePermission in <String>[
      'android.permission.MANAGE_OWN_CALLS',
      'android.permission.CALL_PHONE',
      'android.permission.READ_CALL_LOG',
      'android.permission.WRITE_CALL_LOG',
      'android.permission.READ_PHONE_STATE',
    ]) {
      expect(manifest, isNot(contains(phonePermission)));
    }
    expect(
      manifest,
      isNot(contains('android.permission.USE_FULL_SCREEN_INTENT')),
    );
  });
}
