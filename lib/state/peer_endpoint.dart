import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:whisper/state/ipv4_address_policy.dart';

/// A validated resolved endpoint shared by chat, audio, and remote input.
final class PeerEndpoint {
  factory PeerEndpoint({required String host, required int port}) {
    final normalizedHost = _validateAndNormalizeHost(host);
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be between 1 and 65535');
    }
    return PeerEndpoint._(host: normalizedHost, port: port);
  }

  const PeerEndpoint._({required this.host, required this.port});

  @visibleForTesting
  factory PeerEndpoint.loopbackForTesting({required int port}) {
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be between 1 and 65535');
    }
    return PeerEndpoint._(host: '127.0.0.1', port: port);
  }

  final String host;
  final int port;

  Uri get chatUri => _uri('chat');
  Uri get audioUri => _uri('audio');
  Uri get inputUri => _uri('input');

  Uri _uri(String path) => Uri(
        scheme: 'ws',
        host: _uriHost,
        port: port,
        path: path,
      );

  String get _uriHost {
    final zoneSeparator = host.indexOf('%');
    if (zoneSeparator == -1) {
      return host;
    }
    // Uri accepts escaped host input, so encode only the raw scope delimiter.
    return host.replaceRange(zoneSeparator, zoneSeparator + 1, '%25');
  }

  static String _validateAndNormalizeHost(String host) {
    if (host.isEmpty ||
        host.length > 253 ||
        host.trim() != host ||
        host.contains(RegExp(r'[\x00-\x20/?#@\[\]\\]')) ||
        host.contains('://')) {
      throw ArgumentError.value(host, 'host', 'must be a resolved host');
    }

    if (host.contains(':')) {
      return _validateAndNormalizeIpv6(host);
    }

    final hadTrailingDot = host.endsWith('.');
    final normalized =
        (hadTrailingDot ? host.substring(0, host.length - 1) : host)
            .toLowerCase();
    final ipv4 = Ipv4AddressPolicy.parseCanonical(normalized);
    if (ipv4 != null) {
      if (!Ipv4AddressPolicy.isUsableUnicast(normalized)) {
        throw ArgumentError.value(
          host,
          'host',
          'must be a usable unicast IPv4 address',
        );
      }
      return normalized;
    }

    if (InternetAddress.tryParse(normalized) != null ||
        RegExp(r'^[0-9.]+$').hasMatch(normalized)) {
      throw ArgumentError.value(host, 'host', 'must be a canonical IPv4 host');
    }
    if ((hadTrailingDot && !host.toLowerCase().endsWith('.local.')) ||
        !normalized.endsWith('.local') ||
        normalized == 'localhost.local') {
      throw ArgumentError.value(host, 'host', 'must be an mDNS .local host');
    }

    final localName = normalized.substring(0, normalized.length - 6);
    if (localName.isEmpty ||
        RegExp(r'^[0-9.]+$').hasMatch(localName) ||
        normalized.split('.').any(
              (label) =>
                  label.isEmpty ||
                  label.length > 63 ||
                  !RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')
                      .hasMatch(label),
            )) {
      throw ArgumentError.value(host, 'host', 'must be a valid hostname');
    }
    return normalized;
  }

  static String _validateAndNormalizeIpv6(String host) {
    final zoneSeparator = host.indexOf('%');
    final address =
        zoneSeparator == -1 ? host : host.substring(0, zoneSeparator);
    final zone = zoneSeparator == -1 ? null : host.substring(zoneSeparator + 1);
    if (zone != null &&
        (zone.isEmpty ||
            zone.contains('%') ||
            !RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(zone))) {
      throw ArgumentError.value(host, 'host', 'must have a valid IPv6 zone');
    }

    final parsed = InternetAddress.tryParse(address);
    if (parsed == null || parsed.type != InternetAddressType.IPv6) {
      throw ArgumentError.value(host, 'host', 'must be a valid IPv6 host');
    }
    final bytes = parsed.rawAddress;
    final isIpv4Mapped = bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    final isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
    final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
    final isGlobalUnicast = (bytes[0] & 0xe0) == 0x20;

    if (isIpv4Mapped ||
        (!isLinkLocal && !isUniqueLocal && !isGlobalUnicast) ||
        (isLinkLocal && zone == null) ||
        (!isLinkLocal && zone != null)) {
      throw ArgumentError.value(host, 'host', 'must be a LAN-safe IPv6 host');
    }

    final normalizedAddress = address.toLowerCase();
    return zone == null ? normalizedAddress : '$normalizedAddress%$zone';
  }

  @override
  bool operator ==(Object other) =>
      other is PeerEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'PeerEndpoint($host:$port)';
}
