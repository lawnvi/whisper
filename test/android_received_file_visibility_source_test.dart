import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android received files are scanned after finalizing downloads', () {
    final helper = File('lib/helper/file.dart').readAsStringSync();
    final dirPlugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/DirPlugin.kt',
    ).readAsStringSync();
    final manager =
        File('lib/socket/file_transfer_engine.dart').readAsStringSync();
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
      contains('await _notifyFileVisible(published.path);'),
    );
    expect(
      manager.indexOf('completeIncomingFileTransfer('),
      lessThan(manager.indexOf('await _notifyFileVisible(published.path);')),
    );
  });

  test('Android does not register each received file as it is written', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final helper = File('lib/helper/file.dart').readAsStringSync();
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    // Measured on Android 13: 17 ms per created file without this, 4 with.
    expect(
      manifest,
      contains('android:requestRawExternalStorageAccess="true"'),
    );

    // The system then stops following deletions as well, so a removed file
    // is scanned once more to drop it from galleries and pickers.
    expect(
      helper,
      contains('Future<void> notifyFileRemovedFromAndroidPickers'),
    );
    final deletion = conversation.substring(
      conversation.indexOf('Future<void> _deleteMessages('),
      conversation.indexOf('Future<void> _deleteItems('),
    );
    expect(
      deletion.indexOf('await deleteReceivedMessageFile('),
      lessThan(deletion.indexOf('notifyFileRemovedFromAndroidPickers(')),
    );

    // A received folder is scanned as a whole when it arrives. The pass at
    // launch must not walk into it and queue one scan per file.
    final launchPass = helper.substring(
      helper.indexOf(
        'Future<void> notifyExistingDownloadsVisibleToAndroidPickers',
      ),
      helper.indexOf('void openFile('),
    );
    expect(launchPass, isNot(contains('recursive: true')));
  });
}
