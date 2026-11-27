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
///
/// [resolvedAddresses] are the addresses the platform resolved for the
/// service itself. When it has any that can be used, they stand in for
/// looking [resolvedHost] up.
Future<String?> resolveDiscoveryEndpointHost({
  required String? resolvedHost,
  List<String> resolvedAddresses = const <String>[],
  required String? advertisedHost,
  required int port,
  DiscoveryAddressLookup? lookup,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final candidates = await resolveDiscoveryCandidateHosts(
    resolvedHost: resolvedHost,
    resolvedAddresses: resolvedAddresses,
    advertisedHost: advertisedHost,
    port: port,
    lookup: lookup,
    timeout: timeout,
  );
  return candidates.isEmpty ? null : candidates.first;
}

/// Returns up to [maxCandidates] ordered, deduplicated endpoint hosts for a
/// discovered mDNS service so outgoing dials can race candidate addresses when
/// a peer has multiple network interfaces or stale cached IPs.
Future<List<String>> resolveDiscoveryCandidateHosts({
  required String? resolvedHost,
  List<String> resolvedAddresses = const <String>[],
  required String? advertisedHost,
  required int port,
  DiscoveryAddressLookup? lookup,
  Duration timeout = const Duration(seconds: 2),
  int maxCandidates = 4,
}) async {
  final ordered = <String>[];
  void addHost(String? host) {
    if (host == null ||
        host.isEmpty ||
        ordered.contains(host) ||
        ordered.length >= maxCandidates) {
      return;
    }
    ordered.add(host);
  }

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
  final resolvedIpv4 = <String>[];
  final resolvedIpv6 = <String>[];
  for (final address in resolvedAddresses) {
    final normalized = _normalizeEndpointHost(address, port);
    if (normalized == null || !_isNumericHost(normalized)) {
      continue;
    }
    final targets = _isIpv4Host(normalized) ? resolvedIpv4 : resolvedIpv6;
    if (!targets.contains(normalized)) {
      targets.add(normalized);
    }
  }
  if (resolvedIpv4.isNotEmpty || resolvedIpv6.isNotEmpty) {
    if (advertised != null &&
        (resolvedIpv4.contains(advertised) ||
            resolvedIpv6.contains(advertised))) {
      addHost(advertised);
    }
    for (final address in resolvedIpv4) {
      if (!Ipv4AddressPolicy.isBenchmarking(address)) {
        addHost(address);
      }
    }
    addHost(advertisedFallback);
    for (final address in resolvedIpv4) {
      addHost(address);
    }
    for (final address in resolvedIpv6) {
      addHost(address);
    }
    return List<String>.unmodifiable(ordered);
  }
  if (normalizedResolved == null) {
    // Android NSD advertises names such as Android_XXXX.local. They are valid
    // Bonjour targets but not strict DNS hostnames; only use their validated
    // numeric TXT address, never pass the relaxed name to a socket.
    final localServiceName = resolvedHost?.replaceAll('_', 'a');
    if (resolvedHost?.contains('_') == true &&
        localServiceName != null &&
        _normalizeEndpointHost(localServiceName, port) != null) {
      addHost(advertisedFallback);
    }
    return List<String>.unmodifiable(ordered);
  }
  if (_isNumericHost(normalizedResolved)) {
    // Whisper currently listens on IPv4. Some Bonjour implementations return
    // a scoped link-local IPv6 address even though the peer advertises the
    // IPv4 endpoint that its chat server actually accepts.
    if (!_isIpv4Host(normalizedResolved) && advertisedFallback != null) {
      addHost(advertisedFallback);
      addHost(normalizedResolved);
      return List<String>.unmodifiable(ordered);
    }
    if (Ipv4AddressPolicy.isBenchmarking(normalizedResolved) &&
        advertisedFallback != null) {
      addHost(advertisedFallback);
      addHost(normalizedResolved);
      return List<String>.unmodifiable(ordered);
    }
    addHost(normalizedResolved);
    addHost(advertisedFallback);
    return List<String>.unmodifiable(ordered);
  }

  final resolver = lookup ?? InternetAddress.lookup;
  final List<InternetAddress> addresses;
  try {
    addresses = await resolver(normalizedResolved).timeout(timeout);
  } on Object {
    addHost(advertisedFallback);
    addHost(normalizedResolved);
    return List<String>.unmodifiable(ordered);
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
    addHost(advertised);
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
    addHost(advertisedFallback);
  }
  for (final address in nonBenchmarkIpv4) {
    addHost(address);
  }
  addHost(advertisedFallback);
  for (final address in ipv4) {
    addHost(address);
  }
  for (final address in ipv6) {
    addHost(address);
  }
  if (ordered.isEmpty) {
    addHost(normalizedResolved);
  }
  return List<String>.unmodifiable(ordered);
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
