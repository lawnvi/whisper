import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_packet_transport.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

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

  test('logs packet sends and closed transport drops', () async {
    final logs = <String>[];
    final transport = AudioPacketByteTransport(
      sendBytes: (_) {},
      diagnostics: AudioShareDiagnostics(sink: logs.add),
    );
    final packet = AudioPacketFrame(
      sessionId: 'audio-1',
      sequence: 3,
      captureTimeMicros: 999,
      payload: Uint8List.fromList(<int>[1, 2, 3]),
    );

    transport.send(packet);
    await transport.close();
    transport.send(packet);

    expect(
      logs,
      contains(
        allOf(
          contains('audio packet sent'),
          contains('session=audio-1'),
          contains('seq=3'),
        ),
      ),
    );
    expect(
      logs,
      contains(
        allOf(
          contains('audio packet send dropped'),
          contains('reason=closed'),
        ),
      ),
    );
  });

  test('queued diagnostics stay attached to each packet through drops',
      () async {
    final firstWrite = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final writtenSequences = <int>[];
    final logs = <String>[];
    final byteTransport = PacketByteTransport.audio(
      addStream: (stream) async {
        final bytes = await stream.single as Uint8List;
        writtenSequences.add(AudioPacketFrame.decode(bytes).sequence);
        if (!firstWrite.isCompleted) {
          firstWrite.complete();
          await releaseFirstWrite.future;
        }
      },
      closeSink: () async {},
      maxItems: 2,
      maxBytes: 1024 * 1024,
    );
    final transport = AudioPacketByteTransport.withTransport(
      byteTransport,
      diagnostics: AudioShareDiagnostics(sink: logs.add),
    );
    AudioPacketFrame packet(int sequence) => AudioPacketFrame(
          sessionId: 'audio-sequence',
          sequence: sequence,
          captureTimeMicros: sequence,
          payload: Uint8List.fromList(<int>[sequence]),
        );

    transport.send(packet(1));
    await firstWrite.future;
    transport.send(packet(2));
    transport.send(packet(3));
    releaseFirstWrite.complete();
    await transport.close();

    expect(writtenSequences, <int>[1, 3]);
    final sentLogs =
        logs.where((message) => message.contains('audio packet sent')).toList();
    expect(sentLogs, hasLength(2));
    expect(sentLogs.first, contains('seq=1'));
    expect(sentLogs.last, contains('seq=3'));
    expect(
      logs.singleWhere(
        (message) => message.contains('audio packet send dropped'),
      ),
      allOf(contains('seq=2'), contains('reason=backpressure')),
    );
  });
}
