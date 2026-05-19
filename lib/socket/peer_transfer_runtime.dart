import 'dart:collection';

import 'package:whisper/model/file_transfer.dart';

enum TransferRuntimeDecision {
  started,
  queued,
}

class PeerTransferRuntime {
  String? activeIncoming;
  String? activeOutgoing;
  final Queue<String> queuedIncoming = Queue<String>();
  final Queue<String> queuedOutgoing = Queue<String>();

  TransferRuntimeDecision enqueue({
    required String transferId,
    required FileTransferDirection direction,
  }) {
    switch (direction) {
      case FileTransferDirection.incoming:
        if (activeIncoming == transferId) {
          return TransferRuntimeDecision.started;
        }
        if (queuedIncoming.contains(transferId)) {
          return TransferRuntimeDecision.queued;
        }
        if (activeIncoming == null) {
          activeIncoming = transferId;
          return TransferRuntimeDecision.started;
        }
        queuedIncoming.add(transferId);
        return TransferRuntimeDecision.queued;
      case FileTransferDirection.outgoing:
        if (activeOutgoing == transferId) {
          return TransferRuntimeDecision.started;
        }
        if (queuedOutgoing.contains(transferId)) {
          return TransferRuntimeDecision.queued;
        }
        if (activeOutgoing == null) {
          activeOutgoing = transferId;
          return TransferRuntimeDecision.started;
        }
        queuedOutgoing.add(transferId);
        return TransferRuntimeDecision.queued;
    }
  }

  String? complete({
    required String transferId,
    required FileTransferDirection direction,
  }) {
    switch (direction) {
      case FileTransferDirection.incoming:
        if (activeIncoming == transferId) {
          final next =
              queuedIncoming.isEmpty ? null : queuedIncoming.removeFirst();
          activeIncoming = null;
          return next;
        }
        queuedIncoming.remove(transferId);
        return activeIncoming;
      case FileTransferDirection.outgoing:
        if (activeOutgoing == transferId) {
          final next =
              queuedOutgoing.isEmpty ? null : queuedOutgoing.removeFirst();
          activeOutgoing = null;
          return next;
        }
        queuedOutgoing.remove(transferId);
        return activeOutgoing;
    }
  }
}

class MultiPeerTransferRuntime {
  final Map<String, PeerTransferRuntime> _peers =
      <String, PeerTransferRuntime>{};

  TransferRuntimeDecision enqueue({
    required String peerId,
    required String transferId,
    required FileTransferDirection direction,
  }) {
    final peer = _peers.putIfAbsent(peerId, PeerTransferRuntime.new);
    return peer.enqueue(transferId: transferId, direction: direction);
  }

  String? activeIncomingFor(String peerId) => _peers[peerId]?.activeIncoming;

  String? activeOutgoingFor(String peerId) => _peers[peerId]?.activeOutgoing;

  List<String> queuedIncomingFor(String peerId) =>
      _peers[peerId]?.queuedIncoming.toList(growable: false) ??
      const <String>[];

  List<String> queuedOutgoingFor(String peerId) =>
      _peers[peerId]?.queuedOutgoing.toList(growable: false) ??
      const <String>[];

  String? complete({
    required String peerId,
    required String transferId,
    required FileTransferDirection direction,
  }) {
    return _peers[peerId]
        ?.complete(transferId: transferId, direction: direction);
  }

  void clearPeer(String peerId) {
    _peers.remove(peerId);
  }

  void clearAll() {
    _peers.clear();
  }
}
