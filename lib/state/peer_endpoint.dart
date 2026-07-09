import 'dart:io';

/// A validated resolved endpoint shared by chat, audio, and remote input.
final class PeerEndpoint {
  factory PeerEndpoint({required String host, required int port}) {
    _validateHost(host);
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be between 1 and 65535');
    }
    return PeerEndpoint._(host: host, port: port);
  }

  const PeerEndpoint._({required this.host, required this.port});

  final String host;
  final int port;

  Uri get chatUri => _uri('chat');
  Uri get audioUri => _uri('audio');
  Uri get inputUri => _uri('input');

  Uri _uri(String path) => Uri(
        scheme: 'ws',
        host: host,
        port: port,
        path: path,
      );

  static void _validateHost(String host) {
    if (host.isEmpty ||
        host.length > 253 ||
        host.trim() != host ||
        host.contains(RegExp(r'[\x00-\x20/?#@\[\]\\]')) ||
        host.contains('://')) {
      throw ArgumentError.value(host, 'host', 'must be a resolved host');
    }

    if (host.contains(':')) {
      final zoneSeparator = host.indexOf('%');
      final address =
          zoneSeparator == -1 ? host : host.substring(0, zoneSeparator);
      final zone =
          zoneSeparator == -1 ? null : host.substring(zoneSeparator + 1);
      if ((zone != null &&
              (zone.isEmpty ||
                  zone.contains('%') ||
                  !RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(zone))) ||
          InternetAddress.tryParse(address)?.type != InternetAddressType.IPv6) {
        throw ArgumentError.value(host, 'host', 'must be a valid IPv6 host');
      }
      return;
    }

    final parsedAddress = InternetAddress.tryParse(host);
    if (parsedAddress != null) {
      if (parsedAddress.type != InternetAddressType.IPv4) {
        throw ArgumentError.value(host, 'host', 'must be a valid host');
      }
      return;
    }

    final hostname =
        host.endsWith('.') ? host.substring(0, host.length - 1) : host;
    if (hostname.isEmpty ||
        hostname.split('.').any(
              (label) =>
                  label.isEmpty ||
                  label.length > 63 ||
                  !RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')
                      .hasMatch(label),
            )) {
      throw ArgumentError.value(host, 'host', 'must be a valid hostname');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PeerEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'PeerEndpoint($host:$port)';
}
