import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/discovery_endpoint_resolver.dart';

void main() {
  test('keeps an already numeric resolved endpoint', () async {
    var lookupCount = 0;

    final host = await resolveDiscoveryEndpointHost(
      resolvedHost: '192.168.1.16',
      advertisedHost: '192.168.1.99',
      port: 10002,
      lookup: (host) async {
        lookupCount += 1;
        return <InternetAddress>[];
      },
    );

    expect(host, '192.168.1.16');
    expect(lookupCount, 0);
  });

  test('turns an mDNS hostname into its advertised verified IPv4', () async {
    final host = await resolveDiscoveryEndpointHost(
      resolvedHost: 'macbook-air.local.',
      advertisedHost: '192.168.1.16',
      port: 10002,
      lookup: (_) async => <InternetAddress>[
        InternetAddress('192.168.1.18'),
        InternetAddress('192.168.1.16'),
      ],
    );

    expect(host, '192.168.1.16');
  });

  test('prefers a resolved IPv4 when TXT advertises another address', () async {
    final host = await resolveDiscoveryEndpointHost(
      resolvedHost: 'macbook-air.local',
      advertisedHost: '10.0.0.9',
      port: 10002,
      lookup: (_) async => <InternetAddress>[
        InternetAddress('2001:db8::7'),
        InternetAddress('192.168.1.16'),
      ],
    );

    expect(host, '192.168.1.16');
  });

  test('keeps the mDNS endpoint when numeric resolution fails', () async {
    final host = await resolveDiscoveryEndpointHost(
      resolvedHost: 'macbook-air.local',
      advertisedHost: '192.168.1.16',
      port: 10002,
      lookup: (_) async => throw const SocketException('lookup failed'),
    );

    expect(host, 'macbook-air.local');
  });

  test(
    'rejects an invalid resolved host instead of trusting TXT data',
    () async {
      final host = await resolveDiscoveryEndpointHost(
        resolvedHost: 'example.com',
        advertisedHost: '192.168.1.16',
        port: 10002,
      );

      expect(host, isNull);
    },
  );
}
