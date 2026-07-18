import 'package:flutter/foundation.dart';
import 'package:whisper/state/discovery_identity.dart';
import 'package:whisper/state/peer_endpoint.dart';

enum PairingInviteError {
  tooLong,
  invalidUri,
  unsupportedVersion,
  invalidHost,
  invalidPort,
  invalidPeerId,
  invalidPublicKeyHash,
}

final class PairingInviteFormatException implements FormatException {
  const PairingInviteFormatException(this.reason);

  final PairingInviteError reason;

  @override
  String get message => 'Invalid pairing invite: ${reason.name}';

  @override
  int? get offset => null;

  @override
  Object? get source => null;

  @override
  String toString() => message;
}

/// A versioned, identity-pinned connection invite intended for QR codes.
@immutable
final class PairingInvite {
  factory PairingInvite({
    required String host,
    required int port,
    required String peerId,
    required String publicKeyHash,
  }) {
    final validatedPort = _validatePort(port);
    final PeerEndpoint endpoint;
    try {
      endpoint = PeerEndpoint(host: host, port: validatedPort);
    } on ArgumentError {
      throw const PairingInviteFormatException(PairingInviteError.invalidHost);
    }
    return PairingInvite._(
      host: endpoint.host,
      port: validatedPort,
      peerId: _validatePeerId(peerId),
      publicKeyHash: _validatePublicKeyHash(publicKeyHash),
    );
  }

  const PairingInvite._({
    required this.host,
    required this.port,
    required this.peerId,
    required this.publicKeyHash,
  });

  static const int currentVersion = 1;
  static const int maxEncodedLength = 512;

  static final RegExp _canonicalPeerId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  final String host;
  final int port;
  final String peerId;
  final String publicKeyHash;

  factory PairingInvite.parse(String value) {
    if (value.length > maxEncodedLength) {
      throw const PairingInviteFormatException(PairingInviteError.tooLong);
    }
    if (value.isEmpty || value.trim() != value) {
      throw const PairingInviteFormatException(PairingInviteError.invalidUri);
    }

    final Uri uri;
    try {
      uri = Uri.parse(value);
    } on FormatException {
      throw const PairingInviteFormatException(PairingInviteError.invalidUri);
    }
    if (!value.startsWith('whisper://pair?') ||
        uri.scheme != 'whisper' ||
        uri.authority != 'pair' ||
        uri.path.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const PairingInviteFormatException(PairingInviteError.invalidUri);
    }

    final rawFields = value.substring(value.indexOf('?') + 1).split('&');
    const expectedKeys = <String>{'v', 'host', 'port', 'peer', 'pkh'};
    if (rawFields.length != expectedKeys.length) {
      throw const PairingInviteFormatException(PairingInviteError.invalidUri);
    }
    final seenKeys = <String>{};
    for (final field in rawFields) {
      final separator = field.indexOf('=');
      if (separator <= 0 || separator != field.lastIndexOf('=')) {
        throw const PairingInviteFormatException(PairingInviteError.invalidUri);
      }
      final rawKey = field.substring(0, separator);
      if (!expectedKeys.contains(rawKey) || !seenKeys.add(rawKey)) {
        throw const PairingInviteFormatException(PairingInviteError.invalidUri);
      }
    }
    if (!setEquals(seenKeys, expectedKeys) ||
        uri.queryParametersAll.values.any((values) => values.length != 1)) {
      throw const PairingInviteFormatException(PairingInviteError.invalidUri);
    }

    final version = uri.queryParameters['v'];
    if (version != '$currentVersion') {
      throw const PairingInviteFormatException(
        PairingInviteError.unsupportedVersion,
      );
    }
    final rawPort = uri.queryParameters['port'] ?? '';
    if (!RegExp(r'^[1-9][0-9]{0,4}$').hasMatch(rawPort)) {
      throw const PairingInviteFormatException(PairingInviteError.invalidPort);
    }

    return PairingInvite(
      host: uri.queryParameters['host'] ?? '',
      port: int.parse(rawPort),
      peerId: uri.queryParameters['peer'] ?? '',
      publicKeyHash: uri.queryParameters['pkh'] ?? '',
    );
  }

  String encode() {
    return Uri(
      scheme: 'whisper',
      host: 'pair',
      queryParameters: <String, String>{
        'v': '$currentVersion',
        'host': host,
        'port': '$port',
        'peer': peerId,
        'pkh': publicKeyHash,
      },
    ).toString();
  }

  static int _validatePort(int port) {
    if (port < 1 || port > 65535) {
      throw const PairingInviteFormatException(PairingInviteError.invalidPort);
    }
    return port;
  }

  static String _validatePeerId(String value) {
    if (!_canonicalPeerId.hasMatch(value)) {
      throw const PairingInviteFormatException(
        PairingInviteError.invalidPeerId,
      );
    }
    return value;
  }

  static String _validatePublicKeyHash(String value) {
    if (!DiscoveryIdentity.isCanonicalPublicKeyHash(value)) {
      throw const PairingInviteFormatException(
        PairingInviteError.invalidPublicKeyHash,
      );
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is PairingInvite &&
      other.host == host &&
      other.port == port &&
      other.peerId == peerId &&
      other.publicKeyHash == publicKeyHash;

  @override
  int get hashCode => Object.hash(host, port, peerId, publicKeyHash);
}
