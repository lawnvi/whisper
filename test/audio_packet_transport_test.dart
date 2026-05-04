import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_packet_transport.dart';
import 'package:whisper/audio/audio_protocol.dart';

void main() {
  test('sends encoded audio packet bytes to the byte sink', () {
    final sent = <Uint8List>[];
    final transport = AudioPacketByteTransport(sendBytes: sent.add);
    final packet = AudioPacketFrame(
      sessionId: 'audio-1',
      sequence: 3,
      captureTimeMicros: 999,
      payload: Uint8List.fromList(<int>[1, 2, 3]),
    );

    transport.send(packet);

    expect(sent, hasLength(1));
    expect(AudioPacketFrame.decode(sent.single).sequence, 3);
  });

  test('does not send packets after close', () async {
    final sent = <Uint8List>[];
    final transport = AudioPacketByteTransport(sendBytes: sent.add);

    await transport.close();
    transport.send(
      AudioPacketFrame(
        sessionId: 'audio-1',
        sequence: 1,
        captureTimeMicros: 1,
        payload: Uint8List.fromList(<int>[1]),
      ),
    );

    expect(sent, isEmpty);
  });
}
