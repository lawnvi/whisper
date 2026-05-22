import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android received files are scanned after finalizing downloads', () {
    final helper = File('lib/helper/file.dart').readAsStringSync();
    final dirPlugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/DirPlugin.kt',
    ).readAsStringSync();
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();

    expect(dirPlugin, contains('MediaScannerConnection.scanFile'));
    expect(dirPlugin, contains('"scanFile"'));
    expect(helper, contains('Future<void> notifyFileVisibleToAndroidPickers'));
    expect(
      helper,
      contains('Future<void> notifyExistingDownloadsVisibleToAndroidPickers'),
    );
    expect(helper, contains("'scanFile'"));
    expect(
        deviceList, contains('notifyExistingDownloadsVisibleToAndroidPickers'));
    expect(
      manager,
      contains('await notifyFileVisibleToAndroidPickers(finalPath);'),
    );
    expect(
      manager,
      contains('await notifyFileVisibleToAndroidPickers(transfer.finalPath);'),
    );
  });
}
