import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android document picker uses SAF uri access without file picker cache',
      () {
    final activity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt',
    ).readAsStringSync();
    const pluginPath =
        'android/app/src/main/kotlin/com/vireen/whisper/AndroidDocumentPickerPlugin.kt';
    final plugin = File(pluginPath).existsSync()
        ? File(pluginPath).readAsStringSync()
        : '';

    expect(activity, contains('AndroidDocumentPickerPlugin()'));
    expect(plugin, contains('Intent.ACTION_OPEN_DOCUMENT'));
    expect(plugin, contains('Intent.EXTRA_ALLOW_MULTIPLE'));
    expect(plugin, contains('takePersistableUriPermission'));
    expect(plugin, contains('contentResolver.openInputStream'));
    expect(plugin, isNot(contains('/file_picker/')));
  });

  test('conversation routes Android picks through no-copy transfer items', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    final picker = File('lib/helper/whisper_file_picker.dart').existsSync()
        ? File('lib/helper/whisper_file_picker.dart').readAsStringSync()
        : '';

    expect(conversation, contains('helper/whisper_file_picker.dart'));
    expect(conversation, contains('WhisperFilePicker.pickFiles'));
    expect(conversation, contains('sendPickedFileTo(device.uid, item)'));
    expect(
      conversation,
      isNot(contains('FilePicker.platform.pickFiles(allowMultiple: true)')),
    );
    expect(picker, contains('AndroidDocumentPicker'));
    expect(picker, contains('FilePicker.platform.pickFiles'));
  });

  test('socket transfer source can read Android content uri ranges', () {
    final source = File('lib/socket/file_transfer_source.dart').existsSync()
        ? File('lib/socket/file_transfer_source.dart').readAsStringSync()
        : '';
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('AndroidContentUriTransferSource'));
    expect(source, contains('readBytes(uri: uri'));
    expect(source, contains('PathFileTransferSource'));
    expect(manager, contains('sendAndroidContentUriTo'));
    expect(manager, contains('_transferSourceForMessage'));
    expect(manager, contains('source.readRange'));
  });
}
