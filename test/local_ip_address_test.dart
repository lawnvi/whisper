import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/helper.dart';

void main() {
  test('recognizes every RFC1918 IPv4 range used for LAN pairing', () {
    expect(isPrivateLanIpv4('10.0.0.8'), isTrue);
    expect(isPrivateLanIpv4('172.16.0.8'), isTrue);
    expect(isPrivateLanIpv4('172.31.255.254'), isTrue);
    expect(isPrivateLanIpv4('192.168.50.8'), isTrue);
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
      expect(isPrivateLanIpv4(address), isFalse, reason: address);
    }
  });
}
