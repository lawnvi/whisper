import 'dart:collection';
import 'dart:convert';

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
  static String get protocolVersion => '${PeerSocketSession.protocolVersion}';

  Map<String, String> get txt => UnmodifiableMapView<String, String>(
        <String, String>{
          'v': protocolVersion,
          'pkh': publicKeyHash,
        },
      );

  static bool isCanonicalPublicKeyHash(String value) {
    if (value.length != 43 || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
      return false;
    }
    try {
      final bytes = base64Url.decode('$value=');
      return bytes.length == 32 &&
          base64Url.encode(bytes).replaceAll('=', '') == value;
    } on FormatException {
      return false;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveryIdentity &&
      other.publicKeyHash == publicKeyHash &&
      other.serviceInstanceName == serviceInstanceName;

  @override
  int get hashCode => Object.hash(publicKeyHash, serviceInstanceName);
}
