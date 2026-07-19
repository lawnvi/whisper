import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  test('reliable input overflow closes the socket and ends the session',
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
  });
}
