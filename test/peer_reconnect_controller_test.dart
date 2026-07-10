import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';

void main() {
  group('retry policy', () {
    test('uses the full capped base-delay sequence after network failures',
        () async {
      final scheduler = _FakeScheduler();
      final attemptedTargets = <ReconnectTarget>[];
      final controller = _controller(
        scheduler: scheduler,
        attempt: (attempt) {
          attemptedTargets.add(attempt.target);
          return ConnectionAttemptResult.networkFailure;
        },
      );

      controller.scheduleReconnect(_target);
      for (var index = 0; index < 8; index += 1) {
        await scheduler.runNext();
      }

      expect(attemptedTargets, List<ReconnectTarget>.filled(8, _target));
      expect(
        scheduler.scheduledDelays,
        const <Duration>[
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 4),
          Duration(seconds: 8),
          Duration(seconds: 16),
          Duration(seconds: 30),
          Duration(seconds: 60),
          Duration(seconds: 60),
          Duration(seconds: 60),
        ],
      );
    });

    test('applies exactly 0.8 + 0.4 * randomDouble jitter', () async {
      final scheduler = _FakeScheduler();
      final randomValues = <double>[0, 1];
      final controller = _controller(
        scheduler: scheduler,
        randomDouble: () => randomValues.removeAt(0),
        attempt: (_) => ConnectionAttemptResult.networkFailure,
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();

      expect(
        scheduler.scheduledDelays,
        const <Duration>[
          Duration(milliseconds: 800),
          Duration(milliseconds: 2400),
        ],
      );
    });

    test('authenticated success stops retries and resets the delay', () async {
      final scheduler = _FakeScheduler();
      final results = <ConnectionAttemptResult>[
        ConnectionAttemptResult.networkFailure,
        ConnectionAttemptResult.authenticated,
      ];
      final controller = _controller(
        scheduler: scheduler,
        attempt: (_) => results.removeAt(0),
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();
      await scheduler.runNext();

      expect(scheduler.activeTimerCount, 0);
      controller.scheduleReconnect(_target);
      expect(scheduler.scheduledDelays.last, const Duration(seconds: 1));
    });

    for (final result in <ConnectionAttemptResult>[
      ConnectionAttemptResult.cancelled,
      ConnectionAttemptResult.rejected,
    ]) {
      test('$result stops without another retry', () async {
        final scheduler = _FakeScheduler();
        final controller = _controller(
          scheduler: scheduler,
          attempt: (_) => result,
        );

        controller.scheduleReconnect(_target);
        await scheduler.runNext();

        expect(scheduler.activeTimerCount, 0);
        expect(scheduler.scheduledDelays, const [Duration(seconds: 1)]);
        expect(controller.isSuppressed, isFalse);
        controller.scheduleReconnect(_target);
        expect(scheduler.activeTimerCount, 1);
      });
    }

    for (final entry in <({String name, ReconnectAttempt attempt})>[
      (
        name: 'synchronous throw',
        attempt: (_) => throw StateError('sync attempt failure'),
      ),
      (
        name: 'asynchronous throw',
        attempt: (_) => Future<ConnectionAttemptResult>.error(
              StateError('async attempt failure'),
            ),
      ),
    ]) {
      test('${entry.name} stops without being classified as network failure',
          () async {
        final scheduler = _FakeScheduler();
        final controller = _controller(
          scheduler: scheduler,
          attempt: entry.attempt,
        );

        controller.scheduleReconnect(_target);
        await scheduler.runNext();

        expect(controller.attemptCount, 0);
        expect(controller.isAttemptInFlight, isFalse);
        expect(scheduler.activeTimerCount, 0);
        expect(scheduler.scheduledDelays, const [Duration(seconds: 1)]);
      });
    }
  });

  group('endpoint refresh', () {
    test('replaces the target and accelerates a pending timer', () async {
      final scheduler = _FakeScheduler();
      final attemptedTargets = <ReconnectTarget>[];
      final controller = _controller(
        scheduler: scheduler,
        attempt: (attempt) {
          attemptedTargets.add(attempt.target);
          return ConnectionAttemptResult.cancelled;
        },
      );
      final refreshed = ReconnectTarget(
        peerId: _target.peerId,
        host: '192.168.1.21',
        port: 10005,
      );

      controller.scheduleReconnect(_target);
      final staleTimer = scheduler.latestTimer;
      scheduler.advance(const Duration(milliseconds: 250));
      controller.updateTarget(refreshed);

      expect(controller.target, refreshed);
      expect(controller.attemptCount, 0);
      expect(scheduler.activeTimerCount, 1);
      expect(scheduler.scheduledDelays.last, Duration.zero);
      expect(controller.nextAttemptAt, scheduler.now());

      staleTimer.fireEvenIfCancelled();
      await pumpEventQueue();
      expect(attemptedTargets, isEmpty);

      await scheduler.runNext();
      expect(attemptedTargets, [refreshed]);
    });

    test('can retain the remaining deadline while invalidating the old timer',
        () {
      final scheduler = _FakeScheduler();
      final controller = _controller(
        scheduler: scheduler,
        attempt: (_) => ConnectionAttemptResult.cancelled,
      );
      final refreshed = ReconnectTarget(
        peerId: _target.peerId,
        host: '192.168.1.22',
        port: 10004,
      );

      controller.scheduleReconnect(_target);
      final originalDeadline = controller.nextAttemptAt;
      scheduler.advance(const Duration(milliseconds: 250));
      controller.updateTarget(refreshed, accelerate: false);

      expect(scheduler.scheduledDelays.last, const Duration(milliseconds: 750));
      expect(controller.nextAttemptAt, originalDeadline);
    });

    test('new endpoint is attempted while an invalidated attempt is still hung',
        () async {
      final scheduler = _FakeScheduler();
      final staleResult = Completer<ConnectionAttemptResult>();
      final attemptedTargets = <ReconnectTarget>[];
      final attemptContexts = <ReconnectAttemptContext>[];
      var randomReads = 0;
      final controller = _controller(
        scheduler: scheduler,
        randomDouble: () {
          randomReads += 1;
          return 0.5;
        },
        attempt: (attempt) {
          attemptContexts.add(attempt);
          attemptedTargets.add(attempt.target);
          if (attemptedTargets.length == 1) {
            return staleResult.future;
          }
          return ConnectionAttemptResult.cancelled;
        },
      );
      final refreshed = ReconnectTarget(
        peerId: _target.peerId,
        host: '192.168.1.23',
        port: 10004,
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();
      expect(controller.isAttemptInFlight, isTrue);

      controller.updateTarget(refreshed);
      expect(scheduler.activeTimerCount, 1);
      expect(randomReads, 1);
      expect(attemptContexts.single.isCancelled, isTrue);
      await expectLater(attemptContexts.single.whenCancelled, completes);
      expect(scheduler.scheduledDelays.last, Duration.zero);
      await scheduler.runNext();

      expect(controller.attemptCount, 0);
      expect(attemptedTargets, [_target, refreshed]);
      staleResult.complete(ConnectionAttemptResult.networkFailure);
      await pumpEventQueue();
      expect(scheduler.activeTimerCount, 0);
    });

    test('an identical pending endpoint refresh is a complete no-op', () {
      final scheduler = _FakeScheduler();
      var randomReads = 0;
      final controller = _controller(
        scheduler: scheduler,
        randomDouble: () {
          randomReads += 1;
          return 0.5;
        },
        attempt: (_) => ConnectionAttemptResult.cancelled,
      );
      final equalTarget = ReconnectTarget(
        peerId: _target.peerId,
        host: _target.host,
        port: _target.port,
      );

      controller.scheduleReconnect(_target);
      final timer = scheduler.latestTimer;
      final generation = controller.generation;
      final deadline = controller.nextAttemptAt;
      scheduler.advance(const Duration(milliseconds: 250));
      controller.updateTarget(equalTarget);

      expect(controller.generation, generation);
      expect(controller.nextAttemptAt, deadline);
      expect(scheduler.latestTimer, same(timer));
      expect(scheduler.scheduledDelays, const [Duration(seconds: 1)]);
      expect(randomReads, 1);
    });

    test('duplicate reconnect scheduling cannot reset pending work', () async {
      final timerScheduler = _FakeScheduler();
      var randomReads = 0;
      final timerController = _controller(
        scheduler: timerScheduler,
        randomDouble: () {
          randomReads += 1;
          return 0.5;
        },
        attempt: (_) => ConnectionAttemptResult.cancelled,
      );

      timerController.scheduleReconnect(_target);
      final timer = timerScheduler.latestTimer;
      final timerGeneration = timerController.generation;
      timerController.scheduleReconnect(
        ReconnectTarget(
          peerId: _target.peerId,
          host: _target.host,
          port: _target.port,
        ),
      );

      expect(timerController.generation, timerGeneration);
      expect(timerScheduler.latestTimer, same(timer));
      expect(randomReads, 1);

      final attemptScheduler = _FakeScheduler();
      final result = Completer<ConnectionAttemptResult>();
      late ReconnectAttemptContext attemptContext;
      final attemptController = _controller(
        scheduler: attemptScheduler,
        attempt: (attempt) {
          attemptContext = attempt;
          return result.future;
        },
      );
      attemptController.scheduleReconnect(_target);
      await attemptScheduler.runNext();
      final attemptGeneration = attemptController.generation;

      attemptController.scheduleReconnect(_target);

      expect(attemptController.generation, attemptGeneration);
      expect(attemptContext.isCurrent, isTrue);
      expect(attemptScheduler.activeTimerCount, 0);
      result.complete(ConnectionAttemptResult.cancelled);
      await pumpEventQueue();
    });

    test('an identical endpoint does not invalidate an in-flight guard',
        () async {
      final scheduler = _FakeScheduler();
      final result = Completer<ConnectionAttemptResult>();
      late ReconnectAttemptContext attemptContext;
      var registrationSideEffects = 0;
      final controller = _controller(
        scheduler: scheduler,
        attempt: (attempt) async {
          attemptContext = attempt;
          final attemptResult = await result.future;
          if (attempt.isCurrent) {
            registrationSideEffects += 1;
          }
          return attemptResult;
        },
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();
      final generation = controller.generation;
      controller.updateTarget(
        ReconnectTarget(
          peerId: _target.peerId,
          host: _target.host,
          port: _target.port,
        ),
      );

      expect(controller.generation, generation);
      expect(attemptContext.isCurrent, isTrue);
      expect(scheduler.activeTimerCount, 0);
      result.complete(ConnectionAttemptResult.authenticated);
      await pumpEventQueue();
      expect(registrationSideEffects, 1);
    });
  });

  group('eligibility', () {
    test('is re-read before every retry and false suppresses future attempts',
        () async {
      final scheduler = _FakeScheduler();
      var eligible = true;
      var eligibilityReads = 0;
      var attemptCalls = 0;
      final controller = _controller(
        scheduler: scheduler,
        eligibility: (_) {
          eligibilityReads += 1;
          return eligible
              ? ReconnectEligibilityResult.eligible
              : ReconnectEligibilityResult.autoConnectDisabled;
        },
        attempt: (_) {
          attemptCalls += 1;
          return ConnectionAttemptResult.networkFailure;
        },
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();
      eligible = false;
      await scheduler.runNext();

      expect(eligibilityReads, 2);
      expect(attemptCalls, 1);
      expect(controller.isSuppressed, isTrue);
      expect(
        controller.suppressionReasons,
        {ReconnectSuppressionReason.autoConnectDisabled},
      );
      expect(scheduler.activeTimerCount, 0);
    });

    for (final entry in <String,
        ({
      ReconnectEligibilityResult result,
      ReconnectSuppressionReason suppression,
    })>{
      'auto-connect disabled': (
        result: ReconnectEligibilityResult.autoConnectDisabled,
        suppression: ReconnectSuppressionReason.autoConnectDisabled,
      ),
      'identity not pinned': (
        result: ReconnectEligibilityResult.identityUnpinned,
        suppression: ReconnectSuppressionReason.identityUnpinned,
      ),
      'trust revoked': (
        result: ReconnectEligibilityResult.trustRevoked,
        suppression: ReconnectSuppressionReason.trustRevoked,
      ),
    }.entries) {
      test('${entry.key} fails closed before dialing', () async {
        final scheduler = _FakeScheduler();
        var attemptCalls = 0;
        final controller = _controller(
          scheduler: scheduler,
          eligibility: (_) => entry.value.result,
          attempt: (_) {
            attemptCalls += 1;
            return ConnectionAttemptResult.authenticated;
          },
        );

        controller.scheduleReconnect(_target);
        await scheduler.runNext();

        expect(attemptCalls, 0);
        expect(controller.isSuppressed, isTrue);
        expect(
          controller.suppressionReasons,
          {entry.value.suppression},
        );
      });
    }

    test('a late eligibility result cannot dial after cancellation', () async {
      final scheduler = _FakeScheduler();
      final eligible = Completer<ReconnectEligibilityResult>();
      var attemptCalls = 0;
      final controller = _controller(
        scheduler: scheduler,
        eligibility: (_) => eligible.future,
        attempt: (_) {
          attemptCalls += 1;
          return ConnectionAttemptResult.authenticated;
        },
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();
      controller.manualDisconnect();
      eligible.complete(ReconnectEligibilityResult.eligible);
      await pumpEventQueue();

      expect(attemptCalls, 0);
      expect(controller.isSuppressed, isTrue);
    });

    test('an eligibility read error fails closed until explicitly restored',
        () async {
      final scheduler = _FakeScheduler();
      var attemptCalls = 0;
      final controller = _controller(
        scheduler: scheduler,
        eligibility: (_) => Future<ReconnectEligibilityResult>.error(
          StateError('database unavailable'),
        ),
        attempt: (_) {
          attemptCalls += 1;
          return ConnectionAttemptResult.authenticated;
        },
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();

      expect(attemptCalls, 0);
      expect(
        controller.suppressionReasons,
        {ReconnectSuppressionReason.eligibilityCheckFailed},
      );
      controller.autoConnectEnabled();
      expect(controller.isSuppressed, isTrue);
      controller.eligibilityRestored();
      expect(controller.isSuppressed, isFalse);
    });
  });

  group('cancellation and generation', () {
    final suppressors = <String, void Function(PeerReconnectController)>{
      'manual disconnect': (controller) => controller.manualDisconnect(),
      'trust revoke': (controller) => controller.trustRevoked(),
      'auto-connect disable': (controller) => controller.autoConnectDisabled(),
      'identity unpin': (controller) => controller.identityUnpinned(),
    };

    for (final entry in suppressors.entries) {
      test('${entry.key} cancels and suppresses a stale timer', () async {
        final scheduler = _FakeScheduler();
        var attemptCalls = 0;
        final controller = _controller(
          scheduler: scheduler,
          attempt: (_) {
            attemptCalls += 1;
            return ConnectionAttemptResult.networkFailure;
          },
        );

        controller.scheduleReconnect(_target);
        final staleTimer = scheduler.latestTimer;
        entry.value(controller);

        expect(controller.isSuppressed, isTrue);
        expect(controller.hasPendingAttempt, isFalse);
        staleTimer.fireEvenIfCancelled();
        await pumpEventQueue();
        controller.scheduleReconnect(_target);

        expect(attemptCalls, 0);
        expect(scheduler.activeTimerCount, 0);
      });
    }

    test('a late attempt result cannot resurrect a manual disconnect',
        () async {
      final scheduler = _FakeScheduler();
      final result = Completer<ConnectionAttemptResult>();
      late ReconnectAttemptContext attemptContext;
      var registrationSideEffects = 0;
      final controller = _controller(
        scheduler: scheduler,
        attempt: (attempt) async {
          attemptContext = attempt;
          final attemptResult = await result.future;
          if (attempt.isCurrent) {
            registrationSideEffects += 1;
          }
          return attemptResult;
        },
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();
      final generationBeforeCancel = controller.generation;
      expect(attemptContext.isCurrent, isTrue);
      expect(attemptContext.generation, generationBeforeCancel);
      expect(attemptContext.target, _target);
      controller.manualDisconnect();
      expect(attemptContext.isCancelled, isTrue);
      await expectLater(attemptContext.whenCancelled, completes);
      result.complete(ConnectionAttemptResult.networkFailure);
      await pumpEventQueue();

      expect(controller.generation, greaterThan(generationBeforeCancel));
      expect(controller.attemptCount, 0);
      expect(registrationSideEffects, 0);
      expect(scheduler.activeTimerCount, 0);
    });

    test('explicit manual connect can unsuppress without starting a retry',
        () async {
      final scheduler = _FakeScheduler();
      final attemptedTargets = <ReconnectTarget>[];
      final controller = _controller(
        scheduler: scheduler,
        attempt: (attempt) {
          attemptedTargets.add(attempt.target);
          return ConnectionAttemptResult.cancelled;
        },
      );
      final manualTarget = ReconnectTarget(
        peerId: _target.peerId,
        host: '192.168.1.24',
        port: 10004,
      );

      controller.manualDisconnect();
      controller.unsuppressForManualConnect(manualTarget);

      expect(controller.isSuppressed, isFalse);
      expect(controller.target, manualTarget);
      expect(scheduler.activeTimerCount, 0);
      controller.scheduleReconnect(manualTarget);
      await scheduler.runNext();
      expect(attemptedTargets, [manualTarget]);
    });

    test('manager close is final and cannot be manually unsuppressed',
        () async {
      final scheduler = _FakeScheduler();
      var attemptCalls = 0;
      final controller = _controller(
        scheduler: scheduler,
        attempt: (_) {
          attemptCalls += 1;
          return ConnectionAttemptResult.authenticated;
        },
      );

      controller.scheduleReconnect(_target);
      final staleTimer = scheduler.latestTimer;
      controller.close();
      controller.autoConnectEnabled();
      controller.identityPinned();
      controller.trustRestored();
      controller.unsuppressForManualConnect(_target);
      controller.scheduleReconnect(_target);
      staleTimer.fireEvenIfCancelled();
      await pumpEventQueue();

      expect(controller.isClosed, isTrue);
      expect(controller.isSuppressed, isTrue);
      expect(
        controller.suppressionReasons,
        {ReconnectSuppressionReason.managerClosed},
      );
      expect(attemptCalls, 0);
      expect(scheduler.activeTimerCount, 0);
    });

    test('external authenticated signal cancels pending retry and resets count',
        () async {
      final scheduler = _FakeScheduler();
      final controller = _controller(
        scheduler: scheduler,
        attempt: (_) => ConnectionAttemptResult.networkFailure,
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();
      expect(controller.attemptCount, 1);
      controller.authenticated();

      expect(controller.attemptCount, 0);
      expect(controller.hasPendingAttempt, isFalse);
      controller.scheduleReconnect(_target);
      expect(scheduler.scheduledDelays.last, const Duration(seconds: 1));
    });

    test('external authenticated signal invalidates an in-flight attempt',
        () async {
      final scheduler = _FakeScheduler();
      final result = Completer<ConnectionAttemptResult>();
      late ReconnectAttemptContext attemptContext;
      final controller = _controller(
        scheduler: scheduler,
        attempt: (attempt) {
          attemptContext = attempt;
          return result.future;
        },
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();
      controller.authenticated();

      expect(attemptContext.isCancelled, isTrue);
      expect(controller.attemptCount, 0);
      expect(controller.isSuppressed, isFalse);
      result.complete(ConnectionAttemptResult.networkFailure);
      await pumpEventQueue();
      expect(scheduler.activeTimerCount, 0);
    });
  });

  group('suppression recovery', () {
    final cases = <({
      String name,
      ReconnectSuppressionReason reason,
      void Function(PeerReconnectController) restore,
      void Function(PeerReconnectController) suppress,
      void Function(PeerReconnectController) wrongRestore,
    })>[
      (
        name: 'auto-connect setting',
        reason: ReconnectSuppressionReason.autoConnectDisabled,
        suppress: (controller) => controller.autoConnectDisabled(),
        restore: (controller) => controller.autoConnectEnabled(),
        wrongRestore: (controller) => controller.identityPinned(),
      ),
      (
        name: 'identity pin',
        reason: ReconnectSuppressionReason.identityUnpinned,
        suppress: (controller) => controller.identityUnpinned(),
        restore: (controller) => controller.identityPinned(),
        wrongRestore: (controller) => controller.trustRestored(),
      ),
      (
        name: 'trust state',
        reason: ReconnectSuppressionReason.trustRevoked,
        suppress: (controller) => controller.trustRevoked(),
        restore: (controller) => controller.trustRestored(),
        wrongRestore: (controller) => controller.autoConnectEnabled(),
      ),
    ];

    for (final entry in cases) {
      test('${entry.name} only clears its matching suppression', () async {
        final scheduler = _FakeScheduler();
        var attemptCalls = 0;
        final controller = _controller(
          scheduler: scheduler,
          attempt: (_) {
            attemptCalls += 1;
            return ConnectionAttemptResult.cancelled;
          },
        );

        entry.suppress(controller);
        expect(controller.suppressionReasons, {entry.reason});
        entry.wrongRestore(controller);
        expect(controller.suppressionReasons, {entry.reason});
        controller.scheduleReconnect(_target);
        expect(scheduler.activeTimerCount, 0);

        entry.restore(controller);
        expect(controller.isSuppressed, isFalse);
        expect(scheduler.activeTimerCount, 0);
        controller.scheduleReconnect(_target);
        await scheduler.runNext();
        expect(attemptCalls, 1);
      });
    }

    test('eligibility recovery APIs cannot clear manual suppression', () {
      final scheduler = _FakeScheduler();
      final controller = _controller(
        scheduler: scheduler,
        attempt: (_) => ConnectionAttemptResult.authenticated,
      );

      controller.manualDisconnect();
      controller.authenticated();
      controller.autoConnectEnabled();
      controller.identityPinned();
      controller.trustRestored();

      expect(
        controller.suppressionReasons,
        {ReconnectSuppressionReason.manualDisconnect},
      );
      controller.scheduleReconnect(_target);
      expect(scheduler.activeTimerCount, 0);
    });

    test('overlapping suppression reasons are restored independently', () {
      final scheduler = _FakeScheduler();
      final controller = _controller(
        scheduler: scheduler,
        attempt: (_) => ConnectionAttemptResult.authenticated,
      );

      controller.manualDisconnect();
      controller.trustRevoked();
      expect(
        controller.suppressionReasons,
        {
          ReconnectSuppressionReason.manualDisconnect,
          ReconnectSuppressionReason.trustRevoked,
        },
      );

      controller.trustRestored();
      expect(
        controller.suppressionReasons,
        {ReconnectSuppressionReason.manualDisconnect},
      );
      expect(controller.isSuppressed, isTrue);
    });

    test('manual connect only removes manual disconnect suppression', () async {
      final scheduler = _FakeScheduler();
      final controller = _controller(
        scheduler: scheduler,
        eligibility: (_) => Future<ReconnectEligibilityResult>.error(
          StateError('eligibility unavailable'),
        ),
        attempt: (_) => ConnectionAttemptResult.authenticated,
      );
      final manualTarget = ReconnectTarget(
        peerId: _target.peerId,
        host: '192.168.1.25',
        port: 10004,
      );

      controller.scheduleReconnect(_target);
      await scheduler.runNext();
      controller.manualDisconnect();
      controller.trustRevoked();
      controller.autoConnectDisabled();
      controller.identityUnpinned();

      controller.unsuppressForManualConnect(manualTarget);

      expect(controller.target, manualTarget);
      expect(
        controller.suppressionReasons,
        {
          ReconnectSuppressionReason.trustRevoked,
          ReconnectSuppressionReason.autoConnectDisabled,
          ReconnectSuppressionReason.identityUnpinned,
          ReconnectSuppressionReason.eligibilityCheckFailed,
        },
      );
      controller.scheduleReconnect(manualTarget);
      expect(scheduler.activeTimerCount, 0);
    });
  });
}

final ReconnectTarget _target = ReconnectTarget(
  peerId: 'peer-a',
  host: '192.168.1.20',
  port: 10004,
);

PeerReconnectController _controller({
  required _FakeScheduler scheduler,
  required ReconnectAttempt attempt,
  ReconnectEligibility? eligibility,
  ReconnectRandomDouble? randomDouble,
}) {
  return PeerReconnectController(
    clock: scheduler.now,
    timerFactory: scheduler.createTimer,
    randomDouble: randomDouble ?? () => 0.5,
    eligibility: eligibility ?? (_) => ReconnectEligibilityResult.eligible,
    attempt: attempt,
  );
}

final class _FakeScheduler {
  DateTime _now = DateTime.utc(2026, 7, 10, 12);
  final List<_FakeTimer> _timers = <_FakeTimer>[];
  final List<Duration> scheduledDelays = <Duration>[];

  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;

  _FakeTimer get latestTimer => _timers.last;

  DateTime now() => _now;

  Timer createTimer(Duration delay, void Function() callback) {
    scheduledDelays.add(delay);
    final timer = _FakeTimer(_now.add(delay), callback);
    _timers.add(timer);
    return timer;
  }

  void advance(Duration duration) {
    final advanced = _now.add(duration);
    if (_timers.any(
      (timer) => timer.isActive && !timer.dueAt.isAfter(advanced),
    )) {
      throw StateError('advance would pass a pending timer');
    }
    _now = advanced;
  }

  Future<void> runNext() async {
    final active = _timers.where((timer) => timer.isActive).toList()
      ..sort((left, right) => left.dueAt.compareTo(right.dueAt));
    if (active.isEmpty) {
      throw StateError('No timer is pending');
    }
    final timer = active.first;
    _now = timer.dueAt;
    timer.fire();
    await pumpEventQueue();
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this.dueAt, this._callback);

  final DateTime dueAt;
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
