import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/state/ipv4_address_policy.dart';

void main() {
  test('recognizes every RFC1918 IPv4 range used for LAN pairing', () {
    expect(Ipv4AddressPolicy.isPrivate('10.0.0.8'), isTrue);
    expect(Ipv4AddressPolicy.isPrivate('172.16.0.8'), isTrue);
    expect(Ipv4AddressPolicy.isPrivate('172.31.255.254'), isTrue);
    expect(Ipv4AddressPolicy.isPrivate('192.168.50.8'), isTrue);
  });

  test('recognizes usable IPv4 link-local addresses for direct cables', () {
    expect(Ipv4AddressPolicy.isLinkLocal('169.254.1.0'), isTrue);
    expect(Ipv4AddressPolicy.isLinkLocal('169.254.37.25'), isTrue);
    expect(Ipv4AddressPolicy.isLinkLocal('169.254.254.255'), isTrue);
    expect(Ipv4AddressPolicy.isUsableUnicast('169.254.37.25'), isTrue);
    expect(Ipv4AddressPolicy.isLinkLocal('169.254.0.8'), isFalse);
    expect(Ipv4AddressPolicy.isLinkLocal('169.254.255.8'), isFalse);
  });

  test('prefers RFC1918, then other unicast, then IPv4 link-local', () {
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '169.254.37.25', interfaceName: 'en0'),
        (address: '192.168.1.8', interfaceName: 'en0'),
      ]),
      '192.168.1.8',
    );
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '169.254.37.25', interfaceName: 'en0'),
        (address: '100.64.0.8', interfaceName: 'en0'),
      ]),
      '100.64.0.8',
    );
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '224.0.0.251', interfaceName: 'en0'),
        (address: '169.254.37.25', interfaceName: 'en0'),
      ]),
      '169.254.37.25',
    );
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '224.0.0.251', interfaceName: 'en0'),
      ]),
      isNull,
    );
  });

  test('physical link-local outranks Docker and VPN addresses', () {
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '172.17.0.1', interfaceName: 'docker0'),
        (address: '198.18.0.1', interfaceName: 'utun4'),
        (address: '169.254.37.25', interfaceName: 'en0'),
      ]),
      '169.254.37.25',
    );
  });

  test('does not mistake a Windows Local Area Connection for loopback', () {
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '172.17.0.1', interfaceName: 'docker0'),
        (address: '169.254.37.25', interfaceName: 'Local Area Connection'),
      ]),
      '169.254.37.25',
    );
  });

  test('virtual interfaces remain a last-resort fallback', () {
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '198.18.0.1', interfaceName: 'utun4'),
        (address: '172.17.0.1', interfaceName: 'docker0'),
      ]),
      '172.17.0.1',
    );
  });

  test('recognizes usable unicast while rejecting unsafe IPv4 classes', () {
    expect(Ipv4AddressPolicy.isUsableUnicast('100.64.0.8'), isTrue);
    expect(Ipv4AddressPolicy.isUsableUnicast('203.0.113.8'), isTrue);
    expect(Ipv4AddressPolicy.isUsableUnicast('0.0.0.0'), isFalse);
    expect(Ipv4AddressPolicy.isUsableUnicast('127.0.0.1'), isFalse);
    expect(Ipv4AddressPolicy.isUsableUnicast('224.0.0.251'), isFalse);
    expect(Ipv4AddressPolicy.isUsableUnicast('255.255.255.255'), isFalse);
  });

  test('rejects public and malformed IPv4 addresses', () {
    for (final address in <String>[
      '8.8.8.8',
      '172.15.0.1',
      '172.32.0.1',
      '192.169.0.1',
      '192.168.001.1',
      '256.1.1.1',
      'not-an-address',
    ]) {
      expect(Ipv4AddressPolicy.isPrivate(address), isFalse, reason: address);
    }
  });

  test('desktop enumeration explicitly includes IPv4 link-local addresses', () {
    final source = File('lib/helper/helper.dart').readAsStringSync();
    expect(source, contains('type: InternetAddressType.IPv4'));
    expect(source, contains('includeLinkLocal: true'));
  });
}
