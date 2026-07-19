import 'dart:collection';

import 'package:whisper/model/file_transfer.dart';

enum TransferRuntimeDecision {
  started,
  queued,
}

enum TransferRuntimeReleaseKind {
  absent,
  queuedRemoved,
  activeReleased,
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

  TransferRuntimeReleaseKind release({
    required String transferId,
    required FileTransferDirection direction,
  }) {
    switch (direction) {
      case FileTransferDirection.incoming:
        if (activeIncoming == transferId) {
          activeIncoming = null;
          return TransferRuntimeReleaseKind.activeReleased;
        }
        return queuedIncoming.remove(transferId)
            ? TransferRuntimeReleaseKind.queuedRemoved
            : TransferRuntimeReleaseKind.absent;
      case FileTransferDirection.outgoing:
        if (activeOutgoing == transferId) {
          activeOutgoing = null;
          return TransferRuntimeReleaseKind.activeReleased;
        }
        return queuedOutgoing.remove(transferId)
            ? TransferRuntimeReleaseKind.queuedRemoved
            : TransferRuntimeReleaseKind.absent;
    }
  }

  String? claimNext({
    required FileTransferDirection direction,
  }) {
    switch (direction) {
      case FileTransferDirection.incoming:
        if (activeIncoming != null || queuedIncoming.isEmpty) {
          return null;
        }
        return activeIncoming = queuedIncoming.removeFirst();
      case FileTransferDirection.outgoing:
        if (activeOutgoing != null || queuedOutgoing.isEmpty) {
          return null;
        }
        return activeOutgoing = queuedOutgoing.removeFirst();
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

  TransferRuntimeReleaseKind release({
    required String peerId,
    required String transferId,
    required FileTransferDirection direction,
  }) {
    return _peers[peerId]?.release(
          transferId: transferId,
          direction: direction,
        ) ??
        TransferRuntimeReleaseKind.absent;
  }

  String? claimNext({
    required String peerId,
    required FileTransferDirection direction,
  }) {
    return _peers[peerId]?.claimNext(direction: direction);
  }

  void clearPeer(String peerId) {
    _peers.remove(peerId);
  }

  void clearAll() {
    _peers.clear();
  }
}
