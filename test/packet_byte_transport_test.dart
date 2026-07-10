import 'dart:async';
import 'dart:typed_data';

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
    final uri = buildPeerPacketUri(
      host: '192.168.1.2',
      port: 9200,
      path: '/audio',
      queryParameters: const <String, String>{
        'session': 'audio-session',
        'token': 'secret-token',
      },
    );
    expect(uri.scheme, 'ws');
    expect(uri.host, '192.168.1.2');
    expect(uri.port, 9200);
    expect(uri.path, '/audio');
    expect(uri.queryParameters['session'], 'audio-session');
    expect(uri.queryParameters['token'], 'secret-token');
    expect(redactedPacketUri(uri).query, isEmpty);
    expect(redactedPacketUri(uri).toString(), 'ws://192.168.1.2:9200/audio');
  });

  test('structured packet uri preserves scoped IPv6 and redacts all query', () {
    final uri = buildPeerPacketUri(
      host: 'fe80::1%en0',
      port: 9200,
      path: 'input',
      queryParameters: const <String, String>{
        'session': 'input-session',
        'token': 'never-log-me',
      },
    );

    expect(uri.host, 'fe80::1%25en0');
    expect(uri.path, '/input');
    expect(redactedPacketUri(uri).queryParameters, isEmpty);
    expect(redactedPacketUri(uri).toString(), isNot(contains('never-log-me')));
  });

  group('authenticated media packet envelope', () {
    final key = Uint8List.fromList(
      List<int>.generate(32, (index) => index + 1),
    );

    AuthenticatedMediaPacketDecoder decoder({
      String route = '/audio',
      String sessionId = 'session-a',
      Uint8List? mediaMacKey,
      int maxPayloadBytes = 256 * 1024,
    }) {
      return AuthenticatedMediaPacketDecoder(
        route: route,
        sessionId: sessionId,
        mediaMacKey: mediaMacKey ?? key,
        maxPayloadBytes: maxPayloadBytes,
      );
    }

    test('round-trips payloads with an exact monotonic envelope sequence', () {
      final encoder = AuthenticatedMediaPacketEncoder(
        route: '/audio',
        sessionId: 'session-a',
        mediaMacKey: key,
        maxPayloadBytes: 256 * 1024,
      );
      final receiver = decoder();

      expect(receiver.decode(encoder.encode(Uint8List.fromList(<int>[1, 2]))),
          <int>[1, 2]);
      expect(receiver.decode(encoder.encode(Uint8List.fromList(<int>[3]))),
          <int>[3]);
      expect(encoder.nextSequence, 2);
      expect(receiver.expectedSequence, 2);
    });

    test('rejects tamper, wrong key, route, session, and declared length', () {
      final encoded = AuthenticatedMediaPacketEncoder(
        route: '/audio',
        sessionId: 'session-a',
        mediaMacKey: key,
        maxPayloadBytes: 256 * 1024,
      ).encode(Uint8List.fromList(<int>[1, 2, 3]));
      final tampered = Uint8List.fromList(encoded)..last ^= 0xff;
      final wrongLength = Uint8List.fromList(encoded);
      ByteData.sublistView(wrongLength).setUint32(
        AuthenticatedMediaPacketEnvelope.payloadLengthOffset,
        4,
      );
      final wrongKey = Uint8List.fromList(key)..[0] ^= 0xff;

      expect(() => decoder().decode(tampered), throwsFormatException);
      expect(
        () => decoder(mediaMacKey: wrongKey).decode(encoded),
        throwsFormatException,
      );
      expect(
        () => decoder(route: '/input').decode(encoded),
        throwsFormatException,
      );
      expect(
        () => decoder(sessionId: 'session-b').decode(encoded),
        throwsFormatException,
      );
      expect(() => decoder().decode(wrongLength), throwsFormatException);
    });

    test('rejects replay and skipped envelope sequences', () {
      final encoder = AuthenticatedMediaPacketEncoder(
        route: '/input',
        sessionId: 'input-session',
        mediaMacKey: key,
        maxPayloadBytes: 64 * 1024,
      );
      final first = encoder.encode(Uint8List.fromList(<int>[1]));
      final second = encoder.encode(Uint8List.fromList(<int>[2]));
      final replayReceiver = decoder(
        route: '/input',
        sessionId: 'input-session',
        maxPayloadBytes: 64 * 1024,
      );
      replayReceiver.decode(first);

      expect(() => replayReceiver.decode(first), throwsFormatException);
      expect(
        () => decoder(
          route: '/input',
          sessionId: 'input-session',
          maxPayloadBytes: 64 * 1024,
        ).decode(second),
        throwsFormatException,
      );
    });

    test('enforces the route payload cap before authenticating or decoding',
        () {
      final encoder = AuthenticatedMediaPacketEncoder(
        route: '/audio',
        sessionId: 'session-a',
        mediaMacKey: key,
        maxPayloadBytes: 4,
      );
      final maximum = encoder.encode(Uint8List.fromList(<int>[1, 2, 3, 4]));

      expect(decoder(maxPayloadBytes: 4).decode(maximum), <int>[1, 2, 3, 4]);
      expect(
        () => encoder.encode(Uint8List.fromList(<int>[1, 2, 3, 4, 5])),
        throwsArgumentError,
      );
      expect(
        () => decoder(maxPayloadBytes: 3).decode(maximum),
        throwsFormatException,
      );
    });

    test('drop-oldest queue assigns envelope sequence only when written',
        () async {
      final firstWrite = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      final written = <Uint8List>[];
      final transport = PacketByteTransport.audio(
        addStream: (stream) async {
          written.add(await stream.single as Uint8List);
          if (!firstWrite.isCompleted) {
            firstWrite.complete();
            await releaseFirstWrite.future;
          }
        },
        closeSink: () async {},
        maxItems: 2,
        maxBytes: 1024,
        packetEncoder: AuthenticatedMediaPacketEncoder(
          route: '/audio',
          sessionId: 'session-a',
          mediaMacKey: key,
          maxPayloadBytes: 256,
        ),
      );

      transport.send(Uint8List.fromList(<int>[1]));
      await firstWrite.future;
      transport.send(Uint8List.fromList(<int>[2]));
      transport.send(Uint8List.fromList(<int>[3]));
      releaseFirstWrite.complete();
      await transport.close();

      final receiver = decoder(maxPayloadBytes: 256);
      expect(written.map(receiver.decode), <List<int>>[
        <int>[1],
        <int>[3],
      ]);
    });
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

  test('queued audio transport reports a remote close exactly once', () async {
    final incoming = StreamController<dynamic>();
    var sinkCloses = 0;
    final transport = PacketByteTransport.audio(
      incoming: incoming.stream,
      addStream: (stream) => stream.drain<void>(),
      closeSink: () async => sinkCloses += 1,
    );

    final done = transport.done;
    await incoming.close();

    final termination = await done;
    expect(termination.reason, PacketTransportTerminationReason.remoteClosed);
    expect(await transport.send(<int>[1]), PacketSendResult.closed);
    await transport.close();
    expect(sinkCloses, 1);
    expect(await transport.done, same(termination));
  });

  test('queued audio transport reports a remote stream error', () async {
    final incoming = StreamController<dynamic>();
    final transport = PacketByteTransport.audio(
      incoming: incoming.stream,
      addStream: (stream) => stream.drain<void>(),
      closeSink: incoming.close,
    );
    final error = StateError('remote audio stream failed');

    incoming.addError(error);

    final termination = await transport.done;
    expect(termination.reason, PacketTransportTerminationReason.remoteError);
    expect(termination.error, same(error));
    await transport.close();
  });

  test('queued audio transport reports writer failure and closes', () async {
    var sinkCloses = 0;
    final transport = PacketByteTransport.audio(
      addStream: (stream) async {
        await stream.drain<void>();
        throw StateError('writer failed');
      },
      closeSink: () async => sinkCloses += 1,
    );

    expect(
      await transport.send(Uint8List.fromList(<int>[1])),
      PacketSendResult.transportFailure,
    );
    final termination = await transport.done;
    expect(termination.reason, PacketTransportTerminationReason.writerFailure);
    await transport.close();
    expect(sinkCloses, 1);
  });

  test('intentional queued audio close reports local closure only', () async {
    final incoming = StreamController<dynamic>();
    final transport = PacketByteTransport.audio(
      incoming: incoming.stream,
      addStream: (stream) => stream.drain<void>(),
      closeSink: incoming.close,
    );

    await transport.close();

    final termination = await transport.done;
    expect(termination.reason, PacketTransportTerminationReason.localClosed);
    expect(termination.isUnexpected, isFalse);
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

  test('websocket connection errors never expose capability queries', () async {
    final uri = Uri.parse(
      'ws://peer.local:10002/audio?session=session-a&token=secret-token',
    );

    Object? failure;
    try {
      await connectPacketWebSocket(
        uri,
        connector: (_) => Future<PacketWebSocketConnection>.error(
          StateError('failed to connect $uri'),
        ),
      );
    } catch (error) {
      failure = error;
    }

    expect(failure, isNotNull);
    expect(failure.toString(), contains('ws://peer.local:10002/audio'));
    expect(failure.toString(), isNot(contains('secret-token')));
    expect(failure.toString(), isNot(contains('session=session-a')));
    expect(failure.toString(), isNot(contains('?')));
  });
}
