import 'dart:async';

typedef PeerMessageSender = void Function(Object message);
typedef PeerMessageAsyncSender = Future<bool> Function(Object message);
typedef PeerConnectionCloser = Future<void> Function();

final class TransferConnectionBinding {
  const TransferConnectionBinding({
    required this.peerId,
    required this.generation,
  });

  final String peerId;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is TransferConnectionBinding &&
      other.peerId == peerId &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(peerId, generation);
}

class PeerConnectionSnapshot {
  const PeerConnectionSnapshot({
    required this.peerId,
    required this.connectionId,
    this.isConnected = true,
  });

  final String peerId;
  final int connectionId;
  final bool isConnected;

  int get generation => connectionId;

  TransferConnectionBinding get binding => TransferConnectionBinding(
        peerId: peerId,
        generation: connectionId,
      );
}

class PeerConnection {
  PeerConnection({
    required this.peerId,
    required this.connectionId,
    required PeerMessageSender send,
    PeerMessageAsyncSender? sendAsync,
    required PeerConnectionCloser close,
  })  : _send = send,
        _sendAsync = sendAsync,
        _close = close;

  final String peerId;
  final int connectionId;
  final PeerMessageSender _send;
  final PeerMessageAsyncSender? _sendAsync;
  final PeerConnectionCloser _close;
  bool _isClosed = false;

  bool get isConnected => !_isClosed;

  PeerConnectionSnapshot get snapshot => PeerConnectionSnapshot(
        peerId: peerId,
        connectionId: connectionId,
        isConnected: isConnected,
      );

  bool send(Object message) {
    if (_isClosed) {
      return false;
    }
    _send(message);
    return true;
  }

  Future<bool> sendAwaited(Object message) async {
    if (_isClosed) {
      return false;
    }
    final sender = _sendAsync;
    if (sender != null) {
      return sender(message);
    }
    _send(message);
    return true;
  }

  Future<void> close() async {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    await _close();
  }
}

class PeerConnectionRegistry {
  final Map<String, PeerConnection> _connections = <String, PeerConnection>{};
  final Map<String, Future<void>> _lifecycleTails = <String, Future<void>>{};
  final Set<TransferConnectionBinding> _closingBindings =
      <TransferConnectionBinding>{};

  Set<String> get connectedPeerIds => _connections.entries
      .where((entry) => entry.value.isConnected)
      .map((entry) => entry.key)
      .toSet();

  List<PeerConnectionSnapshot> get snapshots => _connections.values
      .map((connection) => connection.snapshot)
      .toList(growable: false);

  bool isConnectedTo(String peerId) {
    return _connections[peerId]?.isConnected == true;
  }

  PeerConnection? connection(String peerId) => _connections[peerId];

  TransferConnectionBinding? currentBinding(String peerId) {
    final connection = _connections[peerId];
    if (connection == null || !connection.isConnected) {
      return null;
    }
    return TransferConnectionBinding(
      peerId: peerId,
      generation: connection.connectionId,
    );
  }

  bool isCurrent(String peerId, int connectionId) {
    return _connections[peerId]?.connectionId == connectionId;
  }

  Future<void> register(
    PeerConnection connection, {
    FutureOr<void> Function(TransferConnectionBinding binding)? afterRemove,
    FutureOr<void> Function(TransferConnectionBinding binding)? afterRegister,
  }) {
    return _serializePeer<void>(connection.peerId, () async {
      final binding = TransferConnectionBinding(
        peerId: connection.peerId,
        generation: connection.connectionId,
      );
      try {
        final previous = _connections[connection.peerId];
        if (previous != null && !identical(previous, connection)) {
          final previousBinding = TransferConnectionBinding(
            peerId: previous.peerId,
            generation: previous.connectionId,
          );
          _connections.remove(connection.peerId);
          try {
            await _closeConnection(previous);
          } finally {
            final callback = afterRemove;
            if (callback != null) {
              await callback(previousBinding);
            }
          }
        }
        final callback = afterRegister;
        if (callback != null) {
          await callback(binding);
        }
        if (!connection.isConnected) {
          throw StateError('peer connection closed during registration');
        }
        _connections[connection.peerId] = connection;
      } catch (error, stackTrace) {
        if (identical(_connections[connection.peerId], connection)) {
          _connections.remove(connection.peerId);
        }
        await _closeConnection(connection);
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
  }

  bool sendTo(String peerId, Object message) {
    final connection = _connections[peerId];
    if (connection == null) {
      return false;
    }
    return connection.send(message);
  }

  Future<bool> sendToAwaited(String peerId, Object message) async {
    final connection = _connections[peerId];
    if (connection == null) {
      return false;
    }
    return connection.sendAwaited(message);
  }

  Future<bool> sendToAwaitedIfCurrent(
    TransferConnectionBinding binding,
    Object message,
  ) async {
    final connection = _connections[binding.peerId];
    if (connection == null || connection.connectionId != binding.generation) {
      return false;
    }
    final sent = await connection.sendAwaited(message);
    return sent &&
        identical(_connections[binding.peerId], connection) &&
        connection.connectionId == binding.generation &&
        connection.isConnected;
  }

  Future<bool> sendTargetedOrDefault({
    required String? peerId,
    required Object message,
    required Future<bool> Function() sendDefault,
  }) {
    if (peerId != null) {
      return sendToAwaited(peerId, message);
    }
    return sendDefault();
  }

  Future<void> disconnect(String peerId) async {
    await disconnectCurrent(peerId);
  }

  Future<bool> removeIfCurrent(
    TransferConnectionBinding binding, {
    FutureOr<void> Function(TransferConnectionBinding binding)? afterRemove,
  }) {
    if (_closingBindings.contains(binding)) {
      return Future<bool>.value(false);
    }
    return _serializePeer<bool>(binding.peerId, () async {
      if (_closingBindings.contains(binding)) {
        return false;
      }
      final connection = _connections[binding.peerId];
      if (connection == null || connection.connectionId != binding.generation) {
        return false;
      }
      _connections.remove(binding.peerId);
      await _closeConnection(connection);
      final callback = afterRemove;
      if (callback != null) {
        await callback(binding);
      }
      return true;
    });
  }

  Future<bool> disconnectCurrent(
    String peerId, {
    FutureOr<void> Function(TransferConnectionBinding binding)? afterRemove,
  }) {
    return _serializePeer<bool>(peerId, () async {
      final connection = _connections.remove(peerId);
      if (connection == null) {
        return false;
      }
      final binding = TransferConnectionBinding(
        peerId: peerId,
        generation: connection.connectionId,
      );
      await _closeConnection(connection);
      final callback = afterRemove;
      if (callback != null) {
        await callback(binding);
      }
      return true;
    });
  }

  Future<void> disconnectAll() async {
    final peerIds = <String>{
      ..._connections.keys,
      ..._lifecycleTails.keys,
    };
    await Future.wait(
      peerIds.map((peerId) => disconnectCurrent(peerId)),
    );
  }

  Future<void> _closeConnection(PeerConnection connection) async {
    final binding = TransferConnectionBinding(
      peerId: connection.peerId,
      generation: connection.connectionId,
    );
    _closingBindings.add(binding);
    try {
      await connection.close();
    } finally {
      _closingBindings.remove(binding);
    }
  }

  Future<T> _serializePeer<T>(
    String peerId,
    FutureOr<T> Function() operation,
  ) {
    final previous = _lifecycleTails[peerId];
    final Future<T> result;
    if (previous == null) {
      result = Future<T>.sync(operation);
    } else {
      result = previous.then<T>((_) => operation());
    }
    final tail = result.then<void>(
      (_) {},
      onError: (_, __) {},
    );
    _lifecycleTails[peerId] = tail;
    unawaited(tail.whenComplete(() {
      if (identical(_lifecycleTails[peerId], tail)) {
        _lifecycleTails.remove(peerId);
      }
    }));
    return result;
  }
}
