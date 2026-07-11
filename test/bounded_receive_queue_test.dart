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

  test('pauses at the low byte watermark and resumes after draining',
      () async {
    final firstGate = Completer<void>();
    var pauses = 0;
    var resumes = 0;
    var overflows = 0;
    final queue = BoundedReceiveQueue(
      maxItems: 8,
      maxBytes: 16,
      pauseBytes: 8,
      resumeItems: 1,
      resumeBytes: 4,
      onPause: () => pauses++,
      onResume: () => resumes++,
      onOverflow: () => overflows++,
    );

    final first = queue.add(4, () => firstGate.future);
    expect(pauses, 0);
    final second = queue.add(4, () async {});
    expect(queue.pendingItems, 2);
    expect(queue.pendingBytes, 8);
    expect(pauses, 1);
    expect(queue.isPaused, isTrue);

    // pause 之后仍可能有已在事件队列中的在途项到达:必须接收,不是溢出。
    final inFlight = queue.add(4, () async {});
    expect(overflows, 0);
    expect(queue.pendingBytes, 12);

    firstGate.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(await inFlight, isTrue);
    expect(resumes, 1);
    expect(queue.isPaused, isFalse);
    expect(overflows, 0);
  });

  test('a paused queue still counts item watermarks toward pause once',
      () async {
    final gate = Completer<void>();
    var pauses = 0;
    final queue = BoundedReceiveQueue(
      maxItems: 2,
      maxBytes: 1024,
      pauseBytes: 512,
      resumeItems: 0,
      resumeBytes: 1,
      onPause: () => pauses++,
    );

    final first = queue.add(1, () => gate.future);
    final second = queue.add(1, () async {});
    expect(pauses, 1);
    final third = queue.add(1, () async {});
    expect(pauses, 1);

    gate.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(await third, isTrue);
  });

  test('rejects only an item larger than the whole byte budget', () async {
    var pauses = 0;
    var overflows = 0;
    final queue = BoundedReceiveQueue(
      maxItems: 4,
      maxBytes: 8,
      pauseBytes: 4,
      resumeItems: 1,
      resumeBytes: 2,
      onPause: () => pauses++,
      onOverflow: () => overflows++,
    );

    expect(await queue.add(9, () async {}), isFalse);
    expect(overflows, 1);
    expect(pauses, 0);
    expect(queue.pendingItems, 0);
    expect(queue.pendingBytes, 0);

    expect(await queue.add(8, () async {}), isTrue);
    expect(overflows, 1);
  });

  test('overflows only past the hard cap when the peer ignores pause',
      () async {
    final gate = Completer<void>();
    var pauses = 0;
    var overflows = 0;
    final queue = BoundedReceiveQueue(
      maxItems: 16,
      maxBytes: 8,
      pauseBytes: 4,
      resumeItems: 1,
      resumeBytes: 2,
      onPause: () => pauses++,
      onOverflow: () => overflows++,
    );

    final accepted = <Future<bool>>[
      queue.add(4, () => gate.future),
    ];
    expect(pauses, 1);
    // 硬上限 2×maxBytes=16:pause 后继续灌入仍被接收,直到越过硬上限。
    accepted.add(queue.add(4, () async {}));
    accepted.add(queue.add(4, () async {}));
    accepted.add(queue.add(4, () async {}));
    expect(overflows, 0);
    expect(queue.pendingBytes, 16);

    expect(await queue.add(4, () async {}), isFalse);
    expect(overflows, 1);

    gate.complete();
    for (final result in accepted) {
      expect(await result, isTrue);
    }
  });

  test('a 4MiB window of 512KiB wire frames only pauses and never overflows',
      () async {
    // 复现线上死循环入口:fileData 线上帧 ≈524,432B,发送端整窗灌入。
    // 修复前第 16 帧触发 overflow → queue_overflow 断联;
    // 修复后只允许 pause/resume 背压。
    const frameBytes = 524432;
    final firstGate = Completer<void>();
    var pauses = 0;
    var resumes = 0;
    var overflows = 0;
    final queue = BoundedReceiveQueue(
      onPause: () => pauses++,
      onResume: () => resumes++,
      onOverflow: () => overflows++,
    );

    final results = <Future<bool>>[
      queue.add(frameBytes, () => firstGate.future),
    ];
    for (var index = 1; index < 16; index++) {
      results.add(queue.add(frameBytes, () async {}));
    }

    expect(overflows, 0);
    expect(pauses, 1);
    expect(queue.isPaused, isTrue);
    expect(queue.pendingItems, 16);

    firstGate.complete();
    for (final result in results) {
      expect(await result, isTrue);
    }
    expect(overflows, 0);
    expect(resumes, 1);
    expect(queue.isPaused, isFalse);
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
      maxItems: 4,
      maxBytes: 16,
      pauseBytes: 8,
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
