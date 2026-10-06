import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  test(
    'reliable input overflow closes the socket and ends the session',
    () async {
      final incoming = StreamController<dynamic>();
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      var writes = 0;
      var socketCloses = 0;
      final transport = RemoteInputWebSocketPacketTransport.forStreams(
        incoming: incoming.stream,
        addStream: (stream) async {
          await stream.single;
          writes += 1;
          if (writes == 1) {
            firstWriteStarted.complete();
            await releaseFirstWrite.future;
          }
        },
        closeSink: () async => socketCloses += 1,
        maxItems: 2,
        maxBytes: 1024 * 1024,
      );
      final done = transport.done.first;
      RemoteInputPacketFrame packet(int sequence) => RemoteInputPacketFrame(
        sessionId: 'input-overflow',
        sequence: sequence,
        timestampMicros: sequence,
        eventType: RemoteInputEventType.key,
        payload: Uint8List.fromList(<int>[sequence]),
      );

      transport.send(packet(1));
      await firstWriteStarted.future;
      transport.send(packet(2));
      transport.send(packet(3));

      await done;
      releaseFirstWrite.complete();
      await transport.close();
      expect(socketCloses, 1);
      await incoming.close();
    },
  );
  test(
    'manual relative moves remain ordered across clicks during backpressure',
    () async {
      final incoming = StreamController<dynamic>();
      final started = Completer<void>();
      final resume = Completer<void>();
      final delivered = <RemoteInputPacketFrame>[];
      final transport = RemoteInputWebSocketPacketTransport.forStreams(
        incoming: incoming.stream,
        preserveMouseMoves: true,
        addStream: (stream) async {
          final bytes = await stream.single;
          delivered.add(RemoteInputPacketFrame.decode(bytes as Uint8List));
          if (delivered.length == 1) {
            started.complete();
            await resume.future;
          }
        },
        closeSink: () async {},
      );
      void send(int seq, RemoteInputEventType type) => transport.send(
        RemoteInputPacketFrame(
          sessionId: 'manual',
          sequence: seq,
          timestampMicros: seq,
          eventType: type,
          payload: Uint8List.fromList([seq]),
        ),
      );
      send(1, RemoteInputEventType.heartbeat);
      await started.future;
      send(2, RemoteInputEventType.mouseMove);
      send(3, RemoteInputEventType.mouseButton);
      send(4, RemoteInputEventType.mouseMove);
      send(5, RemoteInputEventType.mouseButton);
      send(6, RemoteInputEventType.key);
      resume.complete();
      await transport.close();
      expect(delivered.map((p) => p.sequence), [1, 2, 3, 4, 5, 6]);
      await incoming.close();
    },
  );
}
