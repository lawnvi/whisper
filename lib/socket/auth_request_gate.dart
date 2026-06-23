class AuthRequestGate {
  final Set<String> _incomingPeerIds = <String>{};
  final Set<String> _outgoingRequestKeys = <String>{};

  bool tryClaimIncoming(String peerId) {
    final key = peerId.trim();
    if (key.isEmpty) {
      return true;
    }
    return _incomingPeerIds.add(key);
  }

  void releaseIncoming(String peerId) {
    final key = peerId.trim();
    if (key.isEmpty) {
      return;
    }
    _incomingPeerIds.remove(key);
  }

  bool tryClaimOutgoing(String requestKey) {
    final key = requestKey.trim();
    if (key.isEmpty) {
      return true;
    }
    return _outgoingRequestKeys.add(key);
  }

  void releaseOutgoing(String requestKey) {
    final key = requestKey.trim();
    if (key.isEmpty) {
      return;
    }
    _outgoingRequestKeys.remove(key);
  }

  void clear() {
    _incomingPeerIds.clear();
    _outgoingRequestKeys.clear();
  }
}
