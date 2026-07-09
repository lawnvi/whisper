import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

void main() {
  test('send after close drops with hook, close is idempotent', () async {
    final sentBytes = <Object>[];
    var dropped = 0;
    var closes = 0;
    final transport = PacketByteTransport(
      sendBytes: sentBytes.add,
      closeSink: () async => closes++,
      onPacketDropped: () => dropped++,
    );
    transport.send([1]);
    await transport.close();
    await transport.close();
    transport.send([2]);
    expect(sentBytes, [
      [1]
    ]);
    expect(dropped, 1);
    expect(closes, 1);
    expect(transport.isClosed, isTrue);
  });

  test('buildPeerPacketUri composes ws uri', () {
    final uri =
        buildPeerPacketUri(host: '192.168.1.2', port: 9200, path: '/audio');
    expect(uri.scheme, 'ws');
    expect(uri.host, '192.168.1.2');
    expect(uri.port, 9200);
    expect(uri.path, '/audio');
  });

  test('queued audio transport drains addStream before closing', () async {
    final firstGate = Completer<void>();
    final sent = <Object>[];
    var first = true;
    var sinkClosed = false;
    final transport = PacketByteTransport.audio(
      addStream: (stream) async {
        sent.add(await stream.single);
        if (first) {
          first = false;
          await firstGate.future;
        }
      },
      closeSink: () async => sinkClosed = true,
      maxItems: 2,
      maxBytes: 8,
    );

    transport.send([1, 1, 1, 1]);
    await Future<void>.delayed(Duration.zero);
    transport.send([2, 2, 2, 2]);
    transport.send([3, 3, 3, 3]);

    firstGate.complete();
    await transport.close();
    expect(sent, [
      [1, 1, 1, 1],
      [3, 3, 3, 3],
    ]);
    expect(sinkClosed, isTrue);
  });

  test('queued input transport forwards packet kind for coalescing', () async {
    final firstGate = Completer<void>();
    final sent = <Object>[];
    var first = true;
    final transport = PacketByteTransport.remoteInput(
      addStream: (stream) async {
        sent.add(await stream.single);
        if (first) {
          first = false;
          await firstGate.future;
        }
      },
      closeSink: () async {},
      maxItems: 3,
      maxBytes: 12,
    );

    transport.send(
      [0, 0, 0, 0],
      kind: OutboundPacketKind.key,
    );
    await Future<void>.delayed(Duration.zero);
    transport.send(
      [1, 1, 1, 1],
      kind: OutboundPacketKind.mouseMove,
    );
    transport.send(
      [2, 2, 2, 2],
      kind: OutboundPacketKind.mouseMove,
    );

    firstGate.complete();
    await transport.close();
    expect(sent, [
      [0, 0, 0, 0],
      [2, 2, 2, 2],
    ]);
  });

  test('shared input websocket helper closes on reliable overflow', () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final overflowClosed = Completer<void>();
    var writes = 0;
    final transport = await connectPacketWebSocket(
      Uri.parse('ws://127.0.0.1:10002/input'),
      remoteInputMaxItems: 2,
      remoteInputMaxBytes: 1024,
      connector: (_) async => (
        addStream: (stream) async {
          await stream.single;
          writes += 1;
          if (writes == 1) {
            firstWriteStarted.complete();
            await releaseFirstWrite.future;
          }
        },
        closeSink: () async {
          if (!overflowClosed.isCompleted) {
            overflowClosed.complete();
          }
        },
      ),
    );

    transport.send(
      [1],
      kind: OutboundPacketKind.key,
    );
    await firstWriteStarted.future;
    transport.send(
      [2],
      kind: OutboundPacketKind.key,
    );
    transport.send(
      [3],
      kind: OutboundPacketKind.release,
    );

    await overflowClosed.future;
    releaseFirstWrite.complete();
    await transport.close();
  });
}
