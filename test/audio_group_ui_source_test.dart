import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conversation exposes a multi-sink audio group setup flow', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();

    expect(
        source,
        contains(
            "import 'package:whisper/audio/audio_group_coordinator.dart';"));
    expect(source,
        contains("import 'package:whisper/audio/audio_protocol.dart';"));
    expect(
        source, contains('final AudioGroupCoordinator _audioGroupCoordinator'));
    expect(source, contains('_showAudioGroupSetupSheet'));
    expect(source, contains('connectedAudioGroupSinkDevices'));
    expect(source, contains('sendAudioGroupControlTo'));
    expect(source, contains('AudioChannelRole.left'));
    expect(source, contains('AudioChannelRole.right'));
  });

  test('single selected sink from the group sheet still uses group routing',
      () {
    final source = File('lib/page/conversation.dart').readAsStringSync();

    expect(source, isNot(contains('if (sinks.length > 1)')));
    expect(source, contains('_audioGroupCoordinator.startGroup('));
  });

  test('one connected group-capable sink starts group playback directly', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();

    expect(source, contains('groupCandidates.length == 1'));
    expect(source, contains('device.uid: AudioChannelRole.stereo'));
  });

  test('socket manager exposes connected audio group sink devices for UI', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('List<DeviceData> connectedAudioGroupSinkDevices'));
    expect(source, contains('supportsAudioGroupSinkFor(peerId)'));
    expect(source, contains('preferredPeerId'));
  });
}
