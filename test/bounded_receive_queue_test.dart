import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/bounded_receive_queue.dart';

void main() {
  test('orders work within one socket but not across sockets', () async {
    final firstGate = Completer<void>();
    final calls = <String>[];
    final firstSocket = BoundedReceiveQueue();
    final secondSocket = BoundedReceiveQueue();

    final first = firstSocket.add(1, () async {
      calls.add('first-start');
      await firstGate.future;
      calls.add('first-end');
    });
    final queued = firstSocket.add(1, () async => calls.add('queued'));
    final independent = secondSocket.add(
      1,
      () async => calls.add('independent'),
    );

    await independent;
    expect(calls, ['first-start', 'independent']);
    firstGate.complete();
    expect(await first, isTrue);
    expect(await queued, isTrue);
    expect(calls, ['first-start', 'independent', 'first-end', 'queued']);
  });

  test('counts executing work, pauses at high water and resumes at low water',
      () async {
    final firstGate = Completer<void>();
    var pauses = 0;
    var resumes = 0;
    var overflows = 0;
    final queue = BoundedReceiveQueue(
      maxItems: 2,
      maxBytes: 8,
      resumeItems: 1,
      resumeBytes: 4,
      onPause: () => pauses++,
      onResume: () => resumes++,
      onOverflow: () => overflows++,
    );

    final first = queue.add(4, () => firstGate.future);
    final second = queue.add(4, () async {});
    expect(queue.pendingItems, 2);
    expect(queue.pendingBytes, 8);
    expect(pauses, 1);
    expect(await queue.add(1, () async {}), isFalse);
    expect(overflows, 1);

    firstGate.complete();
    expect(await first, isTrue);
    expect(resumes, 1);
    expect(await second, isTrue);
  });

  test('closeAndDrain waits for active action and rejects later work',
      () async {
    final gate = Completer<void>();
    final queue = BoundedReceiveQueue();
    final active = queue.add(1, () => gate.future);
    var drained = false;
    final drain = queue.closeAndDrain().then((_) => drained = true);

    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    expect(await queue.add(1, () async {}), isFalse);

    gate.complete();
    expect(await active, isTrue);
    await drain;
    expect(drained, isTrue);
  });

  test('pauses and resumes a real stream subscription at watermarks', () async {
    final controller = StreamController<int>();
    final firstGate = Completer<void>();
    final delivered = <int>[];
    late final StreamSubscription<int> subscription;
    late final BoundedReceiveQueue queue;
    queue = BoundedReceiveQueue(
      maxItems: 2,
      maxBytes: 8,
      resumeItems: 1,
      resumeBytes: 4,
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
    );
    subscription = controller.stream.listen((value) {
      unawaited(
        queue.add(4, () async {
          delivered.add(value);
          if (value == 1) {
            await firstGate.future;
          }
        }),
      );
    });

    controller
      ..add(1)
      ..add(2)
      ..add(3);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(subscription.isPaused, isTrue);
    expect(delivered, [1]);

    firstGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(delivered, [1, 2, 3]);
    expect(subscription.isPaused, isFalse);

    await subscription.cancel();
    await controller.close();
    await queue.closeAndDrain();
  });
}
