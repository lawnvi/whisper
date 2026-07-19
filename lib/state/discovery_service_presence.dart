final class DiscoveryServiceLoss {
  const DiscoveryServiceLoss({
    required this.peerId,
    required this.stillDiscovered,
  });

  final String peerId;
  final bool stillDiscovered;
}

/// Tracks the service instances that currently advertise each peer.
///
/// Bonjour lost events do not consistently retain TXT attributes, so the
/// resolved service name is remembered here instead of relying on the lost
/// event to repeat the peer id.
final class DiscoveryServicePresenceTracker {
  final Map<String, String> _peerByService = <String, String>{};
  final Map<String, Set<String>> _servicesByPeer = <String, Set<String>>{};

  void resolved({required String serviceKey, required String peerId}) {
    if (serviceKey.isEmpty || peerId.isEmpty) {
      return;
    }
    final previousPeerId = _peerByService[serviceKey];
    if (previousPeerId != null && previousPeerId != peerId) {
      _removeService(previousPeerId, serviceKey);
    }
    _peerByService[serviceKey] = peerId;
    _servicesByPeer.putIfAbsent(peerId, () => <String>{}).add(serviceKey);
  }

  DiscoveryServiceLoss? lost({
    required String serviceKey,
    String? peerIdHint,
  }) {
    final peerId = _peerByService.remove(serviceKey) ?? peerIdHint;
    if (peerId == null || peerId.isEmpty) {
      return null;
    }
    _removeService(peerId, serviceKey);
    return DiscoveryServiceLoss(
      peerId: peerId,
      stillDiscovered: _servicesByPeer.containsKey(peerId),
    );
  }

  void clear() {
    _peerByService.clear();
    _servicesByPeer.clear();
  }

  void _removeService(String peerId, String serviceKey) {
    final services = _servicesByPeer[peerId];
    services?.remove(serviceKey);
    if (services?.isEmpty ?? false) {
      _servicesByPeer.remove(peerId);
    }
  }
}
