import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android manifest registers file and media share targets', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android.intent.action.SEND'));
    expect(manifest, contains('android.intent.action.SEND_MULTIPLE'));
    expect(manifest, contains('android.intent.category.DEFAULT'));
    expect(manifest, contains('android:mimeType="image/*"'));
    expect(manifest, contains('android:mimeType="video/*"'));
    expect(manifest, contains('android:mimeType="audio/*"'));
    expect(manifest, contains('android:mimeType="application/*"'));
    expect(manifest, isNot(contains('android:mimeType="text/plain"')));
  });

  test('MainActivity captures cold and warm Android share intents', () {
    final activity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt',
    ).readAsStringSync();

    expect(activity, contains('ACTION_SEND'));
    expect(activity, contains('ACTION_SEND_MULTIPLE'));
    expect(activity, contains('EXTRA_STREAM'));
    expect(activity, contains('override fun onNewIntent'));
    expect(activity, contains('consumePendingShareUris'));
    expect(activity, contains('stageSharedUris'));
    expect(activity, contains('contentResolver.openInputStream'));
    expect(activity, contains('OpenableColumns.DISPLAY_NAME'));
  });
}
