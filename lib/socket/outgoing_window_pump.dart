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
  OutgoingWindowPump(this._run, {void Function(String peerId)? onInvalidate})
    : _onInvalidate = onInvalidate;

  final Future<void> Function(OutgoingWindowWork work) _run;
  final void Function(String peerId)? _onInvalidate;
  final Map<String, OutgoingWindowWork> _latest =
      <String, OutgoingWindowWork>{};
  final Map<String, String> _peers = <String, String>{};
  final Map<String, int> _epochs = <String, int>{};
  final Set<String> _running = <String>{};
  Completer<void>? _idleCompleter;

  int currentEpoch(String transferId) => _epochs[transferId] ?? 0;

  bool isCurrentEpoch(String transferId, int epoch) =>
      (_epochs[transferId] ?? 0) == epoch;

  void schedule(OutgoingWindowWork work) {
    final id = work.transfer.transferId;
    _peers[id] = work.transfer.peerUid;
    _latest[id] = work;
    if (_running.add(id)) {
      unawaited(_drain(id));
    }
  }

  /// Drops queued work for [transferId] and advances its attempt epoch so any
  /// already-queued or waiting `fileData` frames from the prior attempt are
  /// skipped before encryption/sending.
  void cancel(String transferId, {String? peerId}) {
    final removed = _latest.remove(transferId);
    _epochs[transferId] = (_epochs[transferId] ?? 0) + 1;
    final targetPeer =
        peerId ?? removed?.transfer.peerUid ?? _peers[transferId];
    if (targetPeer != null && targetPeer.isNotEmpty) {
      _onInvalidate?.call(targetPeer);
    }
  }

  void cancelPeer(String peerId) {
    final ids = <String>{
      for (final entry in _latest.entries)
        if (entry.value.transfer.peerUid == peerId) entry.key,
      for (final entry in _peers.entries)
        if (entry.value == peerId) entry.key,
    };
    for (final id in ids) {
      _latest.remove(id);
      _epochs[id] = (_epochs[id] ?? 0) + 1;
    }
    if (peerId.isNotEmpty) {
      _onInvalidate?.call(peerId);
    }
  }

  void clear() {
    final ids = <String>{..._latest.keys, ..._peers.keys, ..._epochs.keys};
    final peers = <String>{
      for (final work in _latest.values) work.transfer.peerUid,
      ..._peers.values,
    };
    _latest.clear();
    for (final id in ids) {
      _epochs[id] = (_epochs[id] ?? 0) + 1;
    }
    for (final peerId in peers) {
      if (peerId.isNotEmpty) {
        _onInvalidate?.call(peerId);
      }
    }
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
