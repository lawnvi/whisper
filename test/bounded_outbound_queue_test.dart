import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';

final class _RecordingStreamWriter {
  final sent = <Object>[];
  Completer<void>? blockFirst;

  Future<void> addStream(Stream<Object> stream) async {
    final value = await stream.single;
    sent.add(value);
    final blocker = blockFirst;
    blockFirst = null;
    await blocker?.future;
  }
}

void main() {
  test('chat queue serializes addStream and fails closed on overflow',
      () async {
    final firstGate = Completer<void>();
    final writer = _RecordingStreamWriter()..blockFirst = firstGate;
    var overflows = 0;
    final queue = BoundedOutboundQueue.chat(
      addStream: writer.addStream,
      maxItems: 2,
      maxBytes: 8,
      onOverflow: () => overflows++,
    );

    final first = queue.add('first', byteLength: 4);
    await Future<void>.delayed(Duration.zero);
    final second = queue.add('second', byteLength: 4);
    expect(await queue.add('third', byteLength: 1), isFalse);
    expect(overflows, 1);

    firstGate.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    await queue.closeAndDrain();
    expect(writer.sent, ['first', 'second']);
  });

  test('audio queue drops the oldest waiting packet', () async {
    final firstGate = Completer<void>();
    final writer = _RecordingStreamWriter()..blockFirst = firstGate;
    final queue = BoundedOutboundQueue.audio(
      addStream: writer.addStream,
      maxItems: 2,
      maxBytes: 8,
    );

    final first = queue.add('first', byteLength: 4);
    await Future<void>.delayed(Duration.zero);
    final dropped = queue.add('second', byteLength: 4);
    final latest = queue.add('third', byteLength: 4);
    expect(await dropped, isFalse);

    firstGate.complete();
    expect(await first, isTrue);
    expect(await latest, isTrue);
    await queue.closeAndDrain();
    expect(writer.sent, ['first', 'third']);
    expect(queue.droppedItems, 1);
  });

  test('remote input coalesces waiting moves but protects key events',
      () async {
    final firstGate = Completer<void>();
    final writer = _RecordingStreamWriter()..blockFirst = firstGate;
    var stopped = 0;
    final queue = BoundedOutboundQueue.remoteInput(
      addStream: writer.addStream,
      maxItems: 3,
      maxBytes: 12,
      onOverflow: () => stopped++,
    );

    final active = queue.add(
      'key-down',
      byteLength: 4,
      kind: OutboundPacketKind.key,
    );
    await Future<void>.delayed(Duration.zero);
    final staleMove = queue.add(
      'move-1',
      byteLength: 4,
      kind: OutboundPacketKind.mouseMove,
    );
    final latestMove = queue.add(
      'move-2',
      byteLength: 4,
      kind: OutboundPacketKind.mouseMove,
    );
    expect(await staleMove, isFalse);

    final button = queue.add(
      'button',
      byteLength: 4,
      kind: OutboundPacketKind.button,
    );
    expect(
      await queue.add(
        'release',
        byteLength: 1,
        kind: OutboundPacketKind.release,
      ),
      isFalse,
    );
    expect(stopped, 1);

    firstGate.complete();
    expect(await active, isTrue);
    expect(await latestMove, isTrue);
    expect(await button, isTrue);
    await queue.closeAndDrain();
    expect(writer.sent, ['key-down', 'move-2', 'button']);
  });

  test('writer failure becomes a false enqueue result and signals once',
      () async {
    var overflows = 0;
    final queue = BoundedOutboundQueue.chat(
      addStream: (_) async => throw StateError('sink closed'),
      onOverflow: () => overflows++,
    );

    expect(await queue.add('message', byteLength: 7), isFalse);
    expect(await queue.add('later', byteLength: 5), isFalse);
    expect(overflows, 1);
    await queue.closeAndDrain();
  });
}
