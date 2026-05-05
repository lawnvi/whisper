import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('foreground keep-alive notification opens the app and shows progress',
      () {
    final service = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'KeepAliveForegroundService.kt',
    ).readAsStringSync();
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/'
      'BackgroundKeepAlivePlugin.kt',
    ).readAsStringSync();
    final dartHelper =
        File('lib/helper/android_background.dart').readAsStringSync();

    expect(service, contains('PendingIntent.getActivity'));
    expect(service, contains('packageManager.getLaunchIntentForPackage'));
    expect(service, contains('.setContentIntent('));
    expect(service, contains('.setProgress(100, progress'));
    expect(service, contains('EXTRA_PROGRESS'));
    expect(service, contains('EXTRA_INDETERMINATE_PROGRESS'));

    expect(plugin, contains('call.argument<Int>("progress")'));
    expect(plugin, contains('call.argument<Boolean>("indeterminateProgress")'));
    expect(dartHelper, contains('class AndroidKeepAliveNotification'));
    expect(dartHelper, contains("'progress': _clampedProgress"));
    expect(dartHelper, contains("'indeterminateProgress':"));
  });

  test('notification listener service is declared for Android settings grant',
      () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final strings =
        File('android/app/src/main/res/values/strings.xml').readAsStringSync();

    expect(
      manifest,
      contains(
        'android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"',
      ),
    );
    expect(manifest, contains('android:exported="false"'));
    expect(
      manifest,
      contains('android:label="@string/notification_listener_label"'),
    );
    expect(
      manifest,
      contains(
        'android:name="android.service.notification.default_filter_types"',
      ),
    );
    expect(strings, contains('<string name="notification_listener_label">'));
  });
}
