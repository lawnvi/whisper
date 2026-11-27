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
    <String, String>{'v': protocolVersion, 'pkh': publicKeyHash},
  );

  /// Merges the protocol version and public-key hash ([txt]) with the LAN
  /// broadcast display attributes kept for nearby discovery.
  Map<String, String> buildBroadcastAttributes({
    required String host,
    required int port,
    required String name,
    required String platform,
    required String uid,
  }) => <String, String>{
    ...txt,
    'host': host,
    'port': port.toString(),
    'name': name,
    'platform': platform,
    'uid': uid,
  };

  /// Whether a discovered peer's TXT attributes allow background auto-connect.
  ///
  /// - Incompatible advertised protocol versions (`v`) skip auto-connect so
  ///   background dialing does not loop; manual clicks still handshake and show
  ///   which device needs an update.
  /// - For an already-paired device ([storedIdentityPublicKey] non-empty), a
  ///   present `pkh` that does not match the stored public key skips
  ///   auto-connect (possible reinstall or spoofing); manual clicks still run
  ///   the handshake identity check. Records without `pkh` are unaffected.
  static bool allowsAutoConnect({
    required Map<String, String> attributes,
    String? storedIdentityPublicKey,
  }) {
    final rawVersion = attributes['v']?.trim() ?? '';
    if (rawVersion.isNotEmpty) {
      final version = int.tryParse(rawVersion);
      if (version == null ||
          version < PeerSocketSession.minimumProtocolVersion ||
          version > PeerSocketSession.protocolVersion) {
        return false;
      }
    }
    final storedKey = storedIdentityPublicKey?.trim() ?? '';
    final rawPkh = attributes['pkh']?.trim() ?? '';
    if (storedKey.isNotEmpty && rawPkh.isNotEmpty) {
      if (!isCanonicalPublicKeyHash(rawPkh)) {
        return false;
      }
      try {
        if (identityPublicKeyHash(storedKey) != rawPkh) {
          return false;
        }
      } on FormatException {
        return false;
      }
    }
    return true;
  }

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
