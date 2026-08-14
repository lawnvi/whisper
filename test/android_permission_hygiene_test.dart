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
    expect(manifest, contains('android.permission.MANAGE_OWN_CALLS'));
    expect(manifest, contains('android.permission.USE_FULL_SCREEN_INTENT'));
  });
}
