import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_packet_transport.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

void main() {
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

  test(
    'queued writer failure is observable through the audio transport',
    () async {
      final byteTransport = PacketByteTransport.audio(
        addStream: (stream) async {
          await stream.drain<void>();
          throw StateError('writer failed');
        },
        closeSink: () async {},
      );
      final transport = AudioPacketByteTransport.withTransport(byteTransport);

      transport.send(
        AudioPacketFrame(
          sessionId: 'audio-failure',
          sequence: 1,
          captureTimeMicros: 1,
          payload: Uint8List.fromList(<int>[1]),
        ),
      );

      final termination = await transport.done;
      expect(
        termination.reason,
        PacketTransportTerminationReason.writerFailure,
      );
      await transport.close();
    },
  );
}
