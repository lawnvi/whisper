import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/connection_request_notification_dismissal.dart';

void main() {
  test('delayed dismiss fires only after grace period', () {
    final timers = <_FakeTimer>[];
    final durations = <Duration>[];
    final dismissal = ConnectionRequestNotificationDismissal(
      timerFactory: (duration, callback) {
        durations.add(duration);
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );
    final removed = <String>[];

    dismissal.schedule(
      'peer-a',
      graceMillis: 3000,
      onDismiss: () {
        removed.add('peer-a');
      },
    );
    expect(durations, <Duration>[const Duration(milliseconds: 3000)]);
    expect(removed, isEmpty);

    timers.single.fire();

    expect(removed, <String>['peer-a']);
  });

  test('new auth request cancels pending delayed dismiss for same peer', () {
    final timers = <_FakeTimer>[];
    final dismissal = ConnectionRequestNotificationDismissal(
      timerFactory: (_, callback) {
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );
    final removed = <String>[];

    dismissal.schedule(
      'peer-a',
      graceMillis: 3000,
      onDismiss: () {
        removed.add('peer-a');
      },
    );
    dismissal.cancelPending('peer-a');
    timers.single.fire();

    expect(removed, isEmpty);
  });

  test('immediate dismiss cancels pending delayed dismiss and runs once', () {
    final timers = <_FakeTimer>[];
    final dismissal = ConnectionRequestNotificationDismissal(
      timerFactory: (_, callback) {
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );
    final removed = <String>[];

    dismissal.schedule(
      'peer-a',
      graceMillis: 3000,
      onDismiss: () {
        removed.add('delayed');
      },
    );
    dismissal.schedule(
      'peer-a',
      graceMillis: 0,
      onDismiss: () {
        removed.add('immediate');
      },
    );
    timers.single.fire();

    expect(removed, <String>['immediate']);
  });
}

class _FakeTimer implements Timer {
  _FakeTimer(this._callback);

  final void Function() _callback;
  var _isActive = true;
  var _tick = 0;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _isActive = false;
  }

  void fire() {
    if (!_isActive) {
      return;
    }
    _isActive = false;
    _tick += 1;
    _callback();
  }
}
