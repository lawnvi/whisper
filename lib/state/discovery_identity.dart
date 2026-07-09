import 'dart:collection';

import 'package:whisper/socket/peer_socket_session.dart';

/// Public-key-derived identifiers that are safe to expose during discovery.
final class DiscoveryIdentity {
  DiscoveryIdentity._({
    required this.publicKeyHash,
    required this.serviceInstanceName,
  });

  factory DiscoveryIdentity.fromPublicKey(String publicKeyBase64Url) {
    final publicKeyHash = identityPublicKeyHash(publicKeyBase64Url);
    return DiscoveryIdentity._(
      publicKeyHash: publicKeyHash,
      serviceInstanceName: 'whisper-${publicKeyHash.substring(0, 8)}',
    );
  }

  final String publicKeyHash;
  final String serviceInstanceName;

  String get pkh => publicKeyHash;
  String get instanceName => serviceInstanceName;

  Map<String, String> get txt => UnmodifiableMapView<String, String>(
        <String, String>{
          'v': '${PeerSocketSession.protocolVersion}',
          'pkh': publicKeyHash,
        },
      );

  @override
  bool operator ==(Object other) =>
      other is DiscoveryIdentity &&
      other.publicKeyHash == publicKeyHash &&
      other.serviceInstanceName == serviceInstanceName;

  @override
  int get hashCode => Object.hash(publicKeyHash, serviceInstanceName);
}
