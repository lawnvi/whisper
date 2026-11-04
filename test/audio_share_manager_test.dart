import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';

void main() {
  test('drops packet bytes for unknown or stopped sessions', () {
    final received = <AudioPacketFrame>[];
    final manager = AudioShareManager(onPacket: received.add);
    final packet = AudioPacketFrame(
      sessionId: 'missing',
      sequence: 1,
      captureTimeMicros: 100,
      payload: Uint8List.fromList(<int>[7, 8, 9]),
    );

    manager.handlePacketBytes(packet.encode());

    expect(received, isEmpty);
  });
}
