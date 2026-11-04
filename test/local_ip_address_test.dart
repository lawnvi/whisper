import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/state/ipv4_address_policy.dart';

void main() {
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

  test('benchmark addresses stay last when a tunnel has a generic name', () {
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '198.18.0.1', interfaceName: 'Meta'),
        (address: '100.64.0.8', interfaceName: 'Ethernet'),
      ]),
      '100.64.0.8',
    );
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '198.18.0.1', interfaceName: 'Meta'),
        (address: '169.254.37.25', interfaceName: 'Ethernet'),
      ]),
      '169.254.37.25',
    );
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '198.18.0.1', interfaceName: 'Meta'),
        (address: '172.17.0.1', interfaceName: 'docker0'),
      ]),
      '172.17.0.1',
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

  test('Wi-Fi Direct driver description does not outrank the LAN', () {
    for (final name in ['本地连接* 10', 'Local Area Connection* 10', '投屏网卡']) {
      expect(
        selectLocalIpv4Address(<LocalIpv4Candidate>[
          (
            address: '192.168.137.1',
            interfaceName: '$name Microsoft Wi-Fi Direct Virtual Adapter #2',
          ),
          (
            address: '192.168.1.200',
            interfaceName: 'WLAN Intel Wi-Fi 6E AX211',
          ),
          (address: '198.18.0.1', interfaceName: 'Meta Meta Tunnel'),
        ]),
        '192.168.1.200',
        reason: name,
      );
    }
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

  // A VPN or proxy tool had put 172.30.203.182 on lo0 of a Mac: it tied with Wi-Fi
  // and came first, and the device told everyone an address that reaches nothing.
  test('never an address on the loopback interface', () {
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '172.30.203.182', interfaceName: 'lo0 '),
        (address: '192.168.41.5', interfaceName: 'en0 '),
      ]),
      '192.168.41.5',
    );
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (address: '172.30.203.182', interfaceName: 'lo '),
      ]),
      isNull,
    );
    expect(
      selectLocalIpv4Address(<LocalIpv4Candidate>[
        (
          address: '169.254.10.1',
          interfaceName: 'Loopback Pseudo-Interface 1 Software Loopback',
        ),
        (address: '10.0.0.3', interfaceName: 'Ethernet Realtek'),
      ]),
      '10.0.0.3',
    );
  });
}
