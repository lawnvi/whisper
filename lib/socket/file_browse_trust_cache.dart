import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/socket/peer_socket_session.dart';

/// Session-scoped trust cache for incoming `FileBrowseControl` requests.
///
/// Avoids hitting the database on every mounted-folder RPC while still
/// re-checking whenever a connection generation changes, a peer rotates its
/// key, or trust/policy is invalidated.
class FileBrowseTrustCache {
  final Map<String, ({int generation, String publicKey, bool trusted})> _cache =
      <String, ({int generation, String publicKey, bool trusted})>{};

  Future<bool> isTrusted(
    PeerSocketSession session,
    Future<DeviceData?> Function(String peerId) fetchDevice,
  ) async {
    final peerId = session.remotePeerId;
    final publicKey = session.remoteIdentityPublicKey;
    if (!session.isAuthenticated || peerId.isEmpty || publicKey.isEmpty) {
      return false;
    }
    final cached = _cache[peerId];
    if (cached != null &&
        cached.generation == session.connectionGeneration &&
        cached.publicKey == publicKey) {
      return cached.trusted;
    }
    final stored = await fetchDevice(peerId);
    final trusted =
        stored?.auth == true &&
        stored?.identityPublicKey.isNotEmpty == true &&
        stored?.identityPublicKey == publicKey;
    _cache[peerId] = (
      generation: session.connectionGeneration,
      publicKey: publicKey,
      trusted: trusted,
    );
    return trusted;
  }

  void invalidate(String peerId) => _cache.remove(peerId);

  void clear() => _cache.clear();
}
