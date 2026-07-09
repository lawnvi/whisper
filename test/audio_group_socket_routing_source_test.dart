import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('websocket manager routes audio group control by explicit peer id', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(
        source,
        contains(
            "import 'package:whisper/audio/audio_group_coordinator.dart';"));
    expect(source, contains('Future<bool> sendAudioGroupControlTo('));
    expect(source, contains('MessageEnum.AudioGroupControl'));
    expect(source, contains('receiverOverride: peerId'));

    final audioGroupCase = RegExp(
      r'case MessageEnum\.AudioGroupControl:[\s\S]*?case MessageEnum\.RemoteInputControl:',
    ).firstMatch(source)!.group(0)!;
    expect(audioGroupCase, contains('AudioGroupControlMessage.fromJson'));
    expect(audioGroupCase,
        contains('AudioGroupCoordinator.shared.handleControlMessage'));
    expect(audioGroupCase, contains('incomingPeerId == null'));
    expect(audioGroupCase,
        contains('sendAudioGroupControlTo(incomingPeerId, control)'));
  });

  test('websocket manager exposes audio group capability checks per peer', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('bool supportsAudioGroupSourceFor(String peerId)'));
    expect(source, contains('bool supportsAudioGroupSinkFor(String peerId)'));
    expect(source, contains('audioGroupSourceV1 == true'));
    expect(source, contains('audioGroupSinkV1 == true'));
  });
}
