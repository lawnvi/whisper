import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/transfer_ack_watchdog.dart';

void main() {
  const binding = TransferConnectionBinding(
    peerId: 'peer-b',
    generation: 7,
  );

  group('TransferAckWatchdog', () {
    test('uses one exact 15 second timer per armed window', () async {
      final scheduler = _FakeTimerScheduler();
      var retransmits = 0;
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);

      watchdog.armWindow(
        transferId: 'transfer-1',
        connection: binding,
        durableOffset: 1024,
        sentEnd: 4096,
        retransmit: (timeout) {
          retransmits += 1;
          return timeout.sentEnd;
        },
        markUnresponsive: (_) {},
      );

      expect(scheduler.delays, const <Duration>[Duration(seconds: 15)]);
      expect(retransmits, 0);
      await scheduler.fireNext();
      expect(retransmits, 1);
    });

    test('retransmits twice then marks only the bound generation unresponsive',
        () async {
      final scheduler = _FakeTimerScheduler();
      final retransmitted = <TransferAckWindow>[];
      final unresponsive = <TransferAckWindow>[];
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);

      watchdog.armWindow(
        transferId: 'transfer-1',
        connection: binding,
        durableOffset: 1024,
        sentEnd: 4096,
        retransmit: (timeout) {
          retransmitted.add(timeout);
          return timeout.sentEnd + 512;
        },
        markUnresponsive: unresponsive.add,
      );

      await scheduler.fireNext();
      await scheduler.fireNext();
      await scheduler.fireNext();

      expect(retransmitted.map((window) => window.attempt), <int>[1, 2]);
      expect(
        retransmitted.map((window) => window.durableOffset),
        <int>[1024, 1024],
      );
      expect(
        retransmitted.map((window) => window.connection),
        everyElement(binding),
      );
      expect(unresponsive.map((window) => window.attempt), <int>[3]);
      expect(unresponsive.single.connection, binding);
      expect(watchdog.currentWindow('transfer-1'), isNull);
      expect(scheduler.activeTimerCount, 0);
    });

    test('acknowledges only the exact current timer identity', () {
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      final current = watchdog.armWindow(
        transferId: 'transfer-1',
        connection: binding,
        durableOffset: 1024,
        sentEnd: 4096,
        retransmit: (_) => 4096,
        markUnresponsive: (_) {},
      );

      final mismatches = <TransferAckWindow>[
        TransferAckWindow(
          transferId: 'transfer-2',
          connection: current.connection,
          durableOffset: current.durableOffset,
          sentEnd: current.sentEnd,
          attempt: current.attempt,
        ),
        TransferAckWindow(
          transferId: current.transferId,
          connection: const TransferConnectionBinding(
            peerId: 'peer-c',
            generation: 7,
          ),
          durableOffset: current.durableOffset,
          sentEnd: current.sentEnd,
          attempt: current.attempt,
        ),
        TransferAckWindow(
          transferId: current.transferId,
          connection: const TransferConnectionBinding(
            peerId: 'peer-b',
            generation: 8,
          ),
          durableOffset: current.durableOffset,
          sentEnd: current.sentEnd,
          attempt: current.attempt,
        ),
        TransferAckWindow(
          transferId: current.transferId,
          connection: current.connection,
          durableOffset: 1023,
          sentEnd: current.sentEnd,
          attempt: current.attempt,
        ),
        TransferAckWindow(
          transferId: current.transferId,
          connection: current.connection,
          durableOffset: current.durableOffset,
          sentEnd: 4095,
          attempt: current.attempt,
        ),
        TransferAckWindow(
          transferId: current.transferId,
          connection: current.connection,
          durableOffset: current.durableOffset,
          sentEnd: current.sentEnd,
          attempt: 2,
        ),
      ];

      for (final mismatch in mismatches) {
        expect(watchdog.acknowledge(mismatch), isFalse);
      }
      expect(watchdog.currentWindow('transfer-1'), current);
      expect(scheduler.activeTimerCount, 1);

      expect(watchdog.acknowledge(current), isTrue);
      expect(watchdog.currentWindow('transfer-1'), isNull);
      expect(scheduler.activeTimerCount, 0);
    });

    test('replacing an acknowledged partial window resets attempt to one',
        () async {
      final scheduler = _FakeTimerScheduler();
      final attempts = <int>[];
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      watchdog.armWindow(
        transferId: 'transfer-1',
        connection: binding,
        durableOffset: 0,
        sentEnd: 4096,
        retransmit: (timeout) {
          attempts.add(timeout.attempt);
          return timeout.sentEnd;
        },
        markUnresponsive: (_) {},
      );

      await scheduler.fireNext();
      final retry = watchdog.currentWindow('transfer-1')!;
      expect(retry.attempt, 2);
      expect(watchdog.acknowledge(retry), isTrue);

      final next = watchdog.armWindow(
        transferId: 'transfer-1',
        connection: binding,
        durableOffset: 2048,
        sentEnd: 6144,
        retransmit: (timeout) {
          attempts.add(timeout.attempt);
          return timeout.sentEnd;
        },
        markUnresponsive: (_) {},
      );
      expect(next.attempt, 1);
      await scheduler.fireNext();
      expect(attempts, <int>[1, 1]);
    });

    test('an acknowledged window without durable progress keeps attempts',
        () async {
      final scheduler = _FakeTimerScheduler();
      final unresponsive = <TransferAckWindow>[];
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      TransferAckWindow arm(int durableOffset) => watchdog.armWindow(
            transferId: 'transfer-1',
            connection: binding,
            durableOffset: durableOffset,
            sentEnd: durableOffset + 4096,
            retransmit: (timeout) => timeout.sentEnd,
            markUnresponsive: unresponsive.add,
          );

      arm(0);
      await scheduler.fireNext();
      final retry = watchdog.currentWindow('transfer-1')!;
      expect(retry.attempt, 2);
      expect(watchdog.acknowledge(retry), isTrue);

      // 无进度 ACK(durableOffset 原地)后的重挂不得把尝试计数清回 1,
      // 否则停滞的对端可以无限续命。
      final rearmed = arm(0);
      expect(rearmed.attempt, 2);

      await scheduler.fireNext();
      expect(watchdog.currentWindow('transfer-1')!.attempt, 3);
      expect(unresponsive, isEmpty);
      await scheduler.fireNext();
      expect(unresponsive.map((window) => window.attempt), <int>[3]);
      expect(watchdog.currentWindow('transfer-1'), isNull);
    });

    test('published windows inherit attempts and reset only on progress',
        () async {
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      TransferAckWindow publish(int durableOffset, int sentEnd) =>
          watchdog.publishWindow(
            transferId: 'transfer-1',
            connection: binding,
            durableOffset: durableOffset,
            sentEnd: sentEnd,
            retransmit: (timeout) => timeout.sentEnd,
            markUnresponsive: (_) {},
          );

      watchdog.armWindow(
        transferId: 'transfer-1',
        connection: binding,
        durableOffset: 0,
        sentEnd: 4096,
        retransmit: (timeout) => timeout.sentEnd,
        markUnresponsive: (_) {},
      );
      await scheduler.fireNext();
      final retry = watchdog.currentWindow('transfer-1')!;
      expect(retry.attempt, 2);
      expect(watchdog.acknowledge(retry), isTrue);

      // 无进度重发过程中的逐帧发布继承尝试计数。
      expect(publish(0, 512).attempt, 2);
      expect(publish(0, 1024).attempt, 2);
      // durable 进度推进后立即复位到 1。
      expect(publish(2048, 4096).attempt, 1);
    });

    test('cancel clears remembered attempts so a fresh session starts at one',
        () async {
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      TransferAckWindow arm() => watchdog.armWindow(
            transferId: 'transfer-1',
            connection: binding,
            durableOffset: 0,
            sentEnd: 4096,
            retransmit: (timeout) => timeout.sentEnd,
            markUnresponsive: (_) {},
          );

      arm();
      await scheduler.fireNext();
      final retry = watchdog.currentWindow('transfer-1')!;
      expect(retry.attempt, 2);
      expect(watchdog.acknowledge(retry), isTrue);
      watchdog.cancel('transfer-1');

      expect(arm().attempt, 1);
    });

    test('independent transfers cancel independently', () {
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      TransferAckWindow arm(String transferId) => watchdog.armWindow(
            transferId: transferId,
            connection: binding,
            durableOffset: 0,
            sentEnd: 1,
            retransmit: (_) => 1,
            markUnresponsive: (_) {},
          );

      final first = arm('transfer-1');
      arm('transfer-2');
      expect(scheduler.activeTimerCount, 2);

      expect(watchdog.acknowledge(first), isTrue);
      expect(watchdog.currentWindow('transfer-1'), isNull);
      expect(watchdog.currentWindow('transfer-2'), isNotNull);
      expect(scheduler.activeTimerCount, 1);
    });

    test('a replaced equal-looking token cannot cancel the new timer', () {
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      TransferAckWindow arm() => watchdog.armWindow(
            transferId: 'transfer-1',
            connection: binding,
            durableOffset: 0,
            sentEnd: 4096,
            retransmit: (_) => 4096,
            markUnresponsive: (_) {},
          );

      final stale = arm();
      final replacement = arm();

      expect(watchdog.acknowledge(stale), isFalse);
      expect(watchdog.currentWindow('transfer-1'), same(replacement));
      expect(scheduler.activeTimerCount, 1);
    });

    test('cancel and close are idempotent and suppress late callbacks',
        () async {
      final scheduler = _FakeTimerScheduler();
      var callbacks = 0;
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      watchdog.armWindow(
        transferId: 'transfer-1',
        connection: binding,
        durableOffset: 0,
        sentEnd: 1,
        retransmit: (_) {
          callbacks += 1;
          return 1;
        },
        markUnresponsive: (_) => callbacks += 1,
      );
      final staleTimer = scheduler.latestTimer;

      watchdog.cancel('transfer-1');
      watchdog.cancel('transfer-1');
      watchdog.close();
      watchdog.close();
      staleTimer.fireEvenIfCancelled();
      await pumpEventQueue();

      expect(callbacks, 0);
      expect(
        () => watchdog.armWindow(
          transferId: 'transfer-2',
          connection: binding,
          durableOffset: 0,
          sentEnd: 1,
          retransmit: (_) => 1,
          markUnresponsive: (_) {},
        ),
        throwsStateError,
      );
    });

    test('ack during retransmit prevents stale cursor update and rearm',
        () async {
      final scheduler = _FakeTimerScheduler();
      final retransmit = Completer<int?>();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      final first = watchdog.armWindow(
        transferId: 'transfer-1',
        connection: binding,
        durableOffset: 0,
        sentEnd: 4096,
        retransmit: (_) => retransmit.future,
        markUnresponsive: (_) {},
      );

      scheduler.latestTimer.fire();
      await pumpEventQueue();
      expect(watchdog.acknowledge(first), isTrue);
      retransmit.complete(8192);
      await pumpEventQueue();

      expect(watchdog.currentWindow('transfer-1'), isNull);
      expect(scheduler.activeTimerCount, 0);
    });

    for (final result in <FutureOr<int?> Function()>[
      () => null,
      () => throw StateError('retransmit failed'),
      () => Future<int?>.error(StateError('async retransmit failed')),
    ]) {
      test('retransmit null or failure does not leak a timer', () async {
        final scheduler = _FakeTimerScheduler();
        final watchdog = TransferAckWatchdog(
          timerFactory: scheduler.createTimer,
        );
        watchdog.armWindow(
          transferId: 'transfer-1',
          connection: binding,
          durableOffset: 0,
          sentEnd: 4096,
          retransmit: (_) => result(),
          markUnresponsive: (_) {},
        );

        await scheduler.fireNext();

        expect(watchdog.currentWindow('transfer-1'), isNull);
        expect(scheduler.activeTimerCount, 0);
      });
    }
  });
}

final class _FakeTimerScheduler {
  final List<_FakeTimer> _timers = <_FakeTimer>[];
  final List<Duration> delays = <Duration>[];

  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;
  _FakeTimer get latestTimer => _timers.last;

  Timer createTimer(Duration delay, void Function() callback) {
    delays.add(delay);
    final timer = _FakeTimer(callback);
    _timers.add(timer);
    return timer;
  }

  Future<void> fireNext() async {
    final timer = _timers.firstWhere((candidate) => candidate.isActive);
    timer.fire();
    await pumpEventQueue();
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this._callback);

  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;

  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    if (!_active) {
      return;
    }
    _active = false;
    _callback();
  }

  void fireEvenIfCancelled() {
    _active = false;
    _callback();
  }
}
