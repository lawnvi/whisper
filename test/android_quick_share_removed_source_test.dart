import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android quick share entry points are removed', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final activity =
        File('android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt')
            .readAsStringSync();
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();

    expect(manifest, isNot(contains('android.intent.action.SEND')));
    expect(manifest, isNot(contains('android.intent.action.SEND_MULTIPLE')));
    expect(manifest, contains('android:launchMode="singleTop"'));
    expect(activity, isNot(contains('QUICK_SHARE_CHANNEL')));
    expect(activity, isNot(contains('consumePendingShareUris')));
    expect(activity, isNot(contains('stageSharedUris')));
    expect(activity, isNot(contains('shareIntentReceived')));
    expect(deviceList, isNot(contains('AndroidQuickShare')));
    expect(deviceList, isNot(contains('_quickShare')));
  });
}
