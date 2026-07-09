typedef PeerMessageSender = void Function(Object message);
typedef PeerMessageAsyncSender = Future<bool> Function(Object message);
typedef PeerConnectionCloser = Future<void> Function();

class PeerConnectionSnapshot {
  const PeerConnectionSnapshot({
    required this.peerId,
    required this.connectionId,
    this.isConnected = true,
  });

  final String peerId;
  final int connectionId;
  final bool isConnected;
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

  bool isCurrent(String peerId, int connectionId) {
    return _connections[peerId]?.connectionId == connectionId;
  }

  Future<void> register(PeerConnection connection) async {
    final previous = _connections[connection.peerId];
    _connections[connection.peerId] = connection;
    if (previous != null && !identical(previous, connection)) {
      await previous.close();
    }
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
    final connection = _connections.remove(peerId);
    await connection?.close();
  }

  Future<bool> removeIfCurrent(String peerId, int connectionId) async {
    final connection = _connections[peerId];
    if (connection == null || connection.connectionId != connectionId) {
      return false;
    }
    _connections.remove(peerId);
    await connection.close();
    return true;
  }

  Future<void> disconnectAll() async {
    final connections = _connections.values.toList(growable: false);
    _connections.clear();
    for (final connection in connections) {
      await connection.close();
    }
  }
}
