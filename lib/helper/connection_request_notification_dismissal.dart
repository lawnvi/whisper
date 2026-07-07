import 'dart:async';

typedef ConnectionRequestDismissalTimerFactory = Timer Function(
  Duration duration,
  void Function() callback,
);

class ConnectionRequestNotificationDismissal {
  ConnectionRequestNotificationDismissal({
    ConnectionRequestDismissalTimerFactory? timerFactory,
  }) : _timerFactory = timerFactory ?? Timer.new;

  final ConnectionRequestDismissalTimerFactory _timerFactory;
  final Map<String, Timer> _timersByPeer = <String, Timer>{};

  void schedule(
    String peerId, {
    required int graceMillis,
    required void Function() onDismiss,
  }) {
    cancelPending(peerId);
    if (graceMillis <= 0) {
      onDismiss();
      return;
    }
    _timersByPeer[peerId] =
        _timerFactory(Duration(milliseconds: graceMillis), () {
      _timersByPeer.remove(peerId);
      onDismiss();
    });
  }

  void cancelPending(String peerId) {
    _timersByPeer.remove(peerId)?.cancel();
  }

  void clear() {
    for (final timer in _timersByPeer.values) {
      timer.cancel();
    }
    _timersByPeer.clear();
  }
}
