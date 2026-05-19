typedef PeerMessageSender = void Function(Object message);
typedef PeerConnectionCloser = Future<void> Function();

class PeerConnectionSnapshot {
  const PeerConnectionSnapshot({
    required this.peerId,
    this.isConnected = true,
  });

  final String peerId;
  final bool isConnected;
}

class PeerConnection {
  PeerConnection({
    required this.peerId,
    required PeerMessageSender send,
    required PeerConnectionCloser close,
  })  : _send = send,
        _close = close;

  final String peerId;
  final PeerMessageSender _send;
  final PeerConnectionCloser _close;
  bool _isClosed = false;

  bool get isConnected => !_isClosed;

  PeerConnectionSnapshot get snapshot => PeerConnectionSnapshot(
        peerId: peerId,
        isConnected: isConnected,
      );

  bool send(Object message) {
    if (_isClosed) {
      return false;
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

  Future<void> register(PeerConnection connection) async {
    final previous = _connections[connection.peerId];
    if (previous != null && !identical(previous, connection)) {
      await previous.close();
    }
    _connections[connection.peerId] = connection;
  }

  bool sendTo(String peerId, Object message) {
    final connection = _connections[peerId];
    if (connection == null) {
      return false;
    }
    return connection.send(message);
  }

  Future<void> disconnect(String peerId) async {
    final connection = _connections.remove(peerId);
    await connection?.close();
  }

  Future<void> disconnectAll() async {
    final connections = _connections.values.toList(growable: false);
    _connections.clear();
    for (final connection in connections) {
      await connection.close();
    }
  }
}
