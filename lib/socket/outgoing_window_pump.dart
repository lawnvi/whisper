import 'dart:async';

import 'package:whisper/model/LocalDatabase.dart';

typedef OutgoingWindowWork = ({
  FileTransferData transfer,
  MessageData message,
  int offset,
});

/// Runs outgoing transfer window sends outside the inbound receive chain so
/// waiting on pacer slices or outbound queue space can never stall inbound
/// frame processing and create a full-duplex TCP deadlock.
final class OutgoingWindowPump {
  OutgoingWindowPump(this._run);

  final Future<void> Function(OutgoingWindowWork work) _run;
  final Map<String, OutgoingWindowWork> _latest =
      <String, OutgoingWindowWork>{};
  final Set<String> _running = <String>{};
  Completer<void>? _idleCompleter;

  void schedule(OutgoingWindowWork work) {
    final id = work.transfer.transferId;
    _latest[id] = work;
    if (_running.add(id)) {
      unawaited(_drain(id));
    }
  }

  void cancel(String transferId) {
    _latest.remove(transferId);
  }

  void cancelPeer(String peerId) {
    _latest.removeWhere((_, work) => work.transfer.peerUid == peerId);
  }

  void clear() {
    _latest.clear();
  }

  Future<void> waitUntilIdle() {
    if (_running.isEmpty && _latest.isEmpty) {
      return Future<void>.value();
    }
    return (_idleCompleter ??= Completer<void>()).future;
  }

  Future<void> _drain(String transferId) async {
    try {
      while (true) {
        final next = _latest.remove(transferId);
        if (next == null) {
          return;
        }
        await _run(next);
      }
    } finally {
      _running.remove(transferId);
      if (_latest.containsKey(transferId) && _running.add(transferId)) {
        unawaited(_drain(transferId));
      } else if (_running.isEmpty && _latest.isEmpty) {
        final completer = _idleCompleter;
        _idleCompleter = null;
        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
      }
    }
  }
}
