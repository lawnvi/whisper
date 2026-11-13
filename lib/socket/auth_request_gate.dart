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

  /// Claims the incoming slot for a peer that has just proved it holds
  /// [presentedPublicKey], and returns the key claimed, or null when taken.
  /// The bare peer id is the slot only for the key pinned for that id: anyone
  /// can name a known id in a hello, and a stranger's key must never keep the
  /// real device out.
  String? tryClaimProven(
    String peerId, {
    required String pinnedPublicKey,
    required String presentedPublicKey,
  }) {
    final key =
        pinnedPublicKey.isNotEmpty && pinnedPublicKey == presentedPublicKey
        ? peerId
        : '$peerId#$presentedPublicKey';
    return tryClaimIncoming(key) ? key : null;
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

  bool hasOutgoing(String requestKey) {
    final key = requestKey.trim();
    if (key.isEmpty) {
      return false;
    }
    return _outgoingRequestKeys.contains(key);
  }

  void clear() {
    _incomingPeerIds.clear();
    _outgoingRequestKeys.clear();
  }
}
