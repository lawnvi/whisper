import 'dart:async';
import 'dart:io';

import 'package:whisper/state/ipv4_address_policy.dart';
import 'package:whisper/state/peer_endpoint.dart';

typedef DiscoveryAddressLookup =
    Future<List<InternetAddress>> Function(String host);

/// Converts an mDNS service target to a numeric endpoint.
///
/// TXT addresses normally need to match the resolved service target. A valid
/// numeric IPv4 TXT address is used as a fallback when `.local` resolution
/// fails, resolves to IPv6, or system DNS returns only benchmark fake-IP
/// answers. Discovery must not select an address the IPv4 chat server cannot
/// accept.
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
  final advertised = _normalizeEndpointHost(advertisedHost, port);
  final advertisedFallback =
      advertised != null &&
          _isIpv4Host(advertised) &&
          !Ipv4AddressPolicy.isBenchmarking(advertised)
      ? advertised
      : null;
  if (normalizedResolved == null) {
    return null;
  }
  if (_isNumericHost(normalizedResolved)) {
    // Whisper currently listens on IPv4. Some Bonjour implementations return
    // a scoped link-local IPv6 address even though the peer advertises the
    // IPv4 endpoint that its chat server actually accepts.
    if (!_isIpv4Host(normalizedResolved) && advertisedFallback != null) {
      return advertisedFallback;
    }
    if (Ipv4AddressPolicy.isBenchmarking(normalizedResolved) &&
        advertisedFallback != null) {
      return advertisedFallback;
    }
    return normalizedResolved;
  }

  final resolver = lookup ?? InternetAddress.lookup;
  final List<InternetAddress> addresses;
  try {
    addresses = await resolver(normalizedResolved).timeout(timeout);
  } on Object {
    return advertisedFallback ?? normalizedResolved;
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

  if (advertised != null &&
      (ipv4.contains(advertised) || ipv6.contains(advertised))) {
    return advertised;
  }

  final nonBenchmarkIpv4 = ipv4
      .where((address) => !Ipv4AddressPolicy.isBenchmarking(address))
      .toList(growable: false);
  if (advertisedFallback != null &&
      ipv4.isNotEmpty &&
      nonBenchmarkIpv4.isEmpty) {
    // 198.18.0.0/15 is reserved for benchmarking and is also commonly used
    // by proxy fake-IP DNS. In that case the .local lookup did not provide a
    // usable mDNS address, so fall back to Whisper's numeric TXT endpoint.
    return advertisedFallback;
  }
  if (nonBenchmarkIpv4.isNotEmpty) {
    return nonBenchmarkIpv4.first;
  }
  if (ipv4.isNotEmpty) {
    return ipv4.first;
  }
  if (ipv6.isNotEmpty) {
    return ipv6.first;
  }
  return advertisedFallback ?? normalizedResolved;
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

bool _isIpv4Host(String host) =>
    InternetAddress.tryParse(host)?.type == InternetAddressType.IPv4;
