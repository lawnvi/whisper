import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop pairing requests reveal and focus the app window', () {
    final helper = File(
      'lib/helper/desktop_window_attention.dart',
    ).readAsStringSync();
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(helper, contains('windowManager.restore()'));
    expect(helper, contains('windowManager.show()'));
    expect(helper, contains('windowManager.focus()'));
    expect(deviceList, contains('revealDesktopWindowForAttention()'));
    expect(conversation, contains('revealDesktopWindowForAttention()'));
  });

  test('server presents only one pairing prompt per socket session', () {
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(manager, contains('session.tryClaimLocalApprovalPrompt()'));
  });

  test('text copy action is rendered inside the message bubble', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(conversation, contains('Widget? trailingAction'));
    expect(conversation, contains('if (trailingAction != null)'));
  });

  test('disconnected conversation header prioritizes the peer endpoint', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(conversation, contains("return '\${device.host}:\${device.port}';"));
    expect(conversation, isNot(contains('String _connectionStatusText()')));
  });

  test('android content uri media previews without creating a local copy', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    final picker = File(
      'android/app/src/main/kotlin/com/vireen/whisper/AndroidDocumentPickerPlugin.kt',
    ).readAsStringSync();

    expect(conversation, contains("path.startsWith('content://')"));
    expect(conversation, contains('BorderRadius.circular(14)'));
    expect(conversation, isNot(contains('padding: const EdgeInsets.all(1)')));
    expect(conversation, contains('AndroidDocumentPicker.shared.openDocument'));
    expect(picker, contains('contentResolver.loadThumbnail'));
    expect(picker, contains('MediaMetadataRetriever'));
    expect(picker, isNot(contains('FileOutputStream')));
  });

  test('conversation image preview opens the available image gallery', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(conversation, contains('_imageGalleryFor(message)'));
    expect(conversation, contains('imageGallery: gallery?.images'));
    expect(conversation, contains('messageList.reversed'));
    expect(conversation, contains('FileTransferState.completed'));
  });
}
