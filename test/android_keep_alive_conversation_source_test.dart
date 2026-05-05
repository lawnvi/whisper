import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'conversation updates Android foreground service for transfers and audio',
      () {
    final source = File('lib/page/conversation.dart').readAsStringSync();

    expect(source, contains('_buildAndroidKeepAliveNotification()'));
    expect(source, contains('androidBackgroundKeepAliveTransferSending'));
    expect(source, contains('androidBackgroundKeepAliveTransferReceiving'));
    expect(source, contains('androidBackgroundKeepAliveAudioSharing'));
    expect(source, contains('androidBackgroundKeepAliveAudioPlaying'));

    final audioHandler = RegExp(
      r'void _handleAudioShareChanged\(\) \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;
    expect(audioHandler, contains('unawaited(_syncAndroidKeepAliveService())'));

    final transferHandler = RegExp(
      r'void onTransferUpdated\(TransferSnapshot snapshot\) \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;
    expect(
      transferHandler,
      contains('unawaited(_syncAndroidKeepAliveService())'),
    );
  });
}
