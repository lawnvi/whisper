import 'dart:async';
import 'dart:io';

import 'package:whisper/state/peer_endpoint.dart';

typedef DiscoveryAddressLookup =
    Future<List<InternetAddress>> Function(String host);

/// Converts an mDNS hostname to a numeric endpoint without trusting a TXT
/// address that was not part of the resolver result.
Future<String?> resolveDiscoveryEndpointHost({
  required String? resolvedHost,
  required String? advertisedHost,
  required int port,
  DiscoveryAddressLookup? lookup,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final hasResolvedHost = resolvedHost?.isNotEmpty == true;
  final normalizedResolved = _normalizeEndpointHost(
    hasResolvedHost ? resolvedHost! : advertisedHost,
    port,
  );
  if (normalizedResolved == null || _isNumericHost(normalizedResolved)) {
    return normalizedResolved;
  }

  final resolver = lookup ?? InternetAddress.lookup;
  final List<InternetAddress> addresses;
  try {
    addresses = await resolver(normalizedResolved).timeout(timeout);
  } on Object {
    return normalizedResolved;
  }

  final ipv4 = <String>[];
  final ipv6 = <String>[];
  for (final address in addresses) {
    final normalized = _normalizeEndpointHost(address.address, port);
    if (normalized == null) {
      continue;
    }
    final targets = address.type == InternetAddressType.IPv4 ? ipv4 : ipv6;
    if (!targets.contains(normalized)) {
      targets.add(normalized);
    }
  }

  final advertised = _normalizeEndpointHost(advertisedHost, port);
  if (advertised != null &&
      (ipv4.contains(advertised) || ipv6.contains(advertised))) {
    return advertised;
  }
  if (ipv4.isNotEmpty) {
    return ipv4.first;
  }
  if (ipv6.isNotEmpty) {
    return ipv6.first;
  }
  return normalizedResolved;
}

String? _normalizeEndpointHost(String? host, int port) {
  if (host == null || host.isEmpty) {
    return null;
  }
  try {
    return PeerEndpoint(host: host, port: port).host;
  } on ArgumentError {
    return null;
  }
}

bool _isNumericHost(String host) {
  final zoneSeparator = host.indexOf('%');
  final address = zoneSeparator == -1 ? host : host.substring(0, zoneSeparator);
  return InternetAddress.tryParse(address) != null;
}
