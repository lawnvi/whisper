import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/share_links/share_lan.dart';
import 'package:whisper/share_links/share_range.dart';
import 'package:whisper/share_links/share_server.dart';

void main() {
  group('Range', () {
    test('open-ended and closed ranges', () {
      expect(
        parseShareRange('bytes=500-', 1000),
        const ShareRangePart(500, 999),
      );
      expect(
        parseShareRange('bytes=10-19', 1000),
        const ShareRangePart(10, 19),
      );
      expect(parseShareRange('bytes=0-0', 1000), const ShareRangePart(0, 0));
      expect(
        parseShareRange('Bytes = 10 - 19', 1000),
        const ShareRangePart(10, 19),
      );
    });

    test('an end past the file is cut to the last byte', () {
      expect(
        parseShareRange('bytes=990-5000', 1000),
        const ShareRangePart(990, 999),
      );
      expect(
        parseShareRange('bytes=5-99999999999999999999999', 1000),
        const ShareRangePart(5, 999),
      );
    });

    test('suffix ranges count from the end', () {
      expect(
        parseShareRange('bytes=-500', 1000),
        const ShareRangePart(500, 999),
      );
      expect(
        parseShareRange('bytes=-5000', 1000),
        const ShareRangePart(0, 999),
      );
      expect(parseShareRange('bytes=-1', 1000), const ShareRangePart(999, 999));
    });

    test('unsatisfiable or malformed ranges are answered with 416', () {
      for (final header in [
        'bytes=1000-',
        'bytes=1000-1001',
        'bytes=5000-',
        'bytes=-0',
        'bytes=20-10',
        'bytes=-',
        'bytes=abc',
        'bytes=1-2-3',
        'bytes',
        'bytes=99999999999999999999-',
      ]) {
        expect(
          parseShareRange(header, 1000),
          isA<ShareRangeUnsatisfiable>(),
          reason: header,
        );
      }
    });

    test('the part lengths add up', () {
      const part = ShareRangePart(100, 199);
      expect(part.length, 100);
    });
  });

  group('content disposition', () {
    test('keeps the real name in RFC 5987 form with an ASCII fallback', () {
      final value = shareContentDisposition('报告 "最终" 100%.pdf');
      expect(value, startsWith('attachment; filename="'));
      expect(value, contains('filename*=UTF-8\'\''));
      expect(value, contains('%E6%8A%A5%E5%91%8A%20'));
      expect(value, contains('%25.pdf'));
      final fallback = RegExp(r'filename="([^"]*)"').firstMatch(value)![1]!;
      expect(fallback.codeUnits.every((u) => u >= 0x20 && u < 0x7f), isTrue);
      expect(fallback, isNot(contains('"')));
      expect(
        shareContentDisposition('a.mp4', inline: true),
        startsWith('inline;'),
      );
    });
  });

  test('Host must name this device the LAN way', () {
    for (final host in [
      null,
      '192.168.31.20:10003',
      '127.0.0.1',
      '[fe80::1]:10003',
      'localhost:10003',
      'macbook.local',
      'macbook.local.',
      'nas',
      'router.lan',
      'pc.home.arpa',
    ]) {
      expect(shareHostAllowed(host), isTrue, reason: host);
    }
    for (final host in ['evil.example.com', 'evil.com:10003', '[nope]']) {
      expect(shareHostAllowed(host), isFalse, reason: host);
    }
  });

  group('LAN filter', () {
    bool lan(String address) => isShareLanAddress(InternetAddress(address));

    test('takes private, link-local and loopback addresses', () {
      for (final address in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.31.20',
        '169.254.10.1',
        '::1',
        'fd12:3456:789a::1',
        'fc00::1',
        'fe80::1c2b:3cff:fe4d:5e6f',
        '::ffff:192.168.1.5',
        '::ffff:10.0.0.1',
      ]) {
        expect(lan(address), isTrue, reason: address);
      }
    });

    test('refuses everything else, carrier-grade NAT included', () {
      for (final address in [
        '8.8.8.8',
        '172.15.0.1',
        '172.32.0.1',
        '192.169.0.1',
        '100.63.255.255',
        '100.64.0.1',
        '100.100.100.100',
        '100.127.255.254',
        '::ffff:100.64.0.1',
        '100.128.0.1',
        '1.1.1.1',
        '2001:4860:4860::8888',
        '2408:8000::1',
        'fec0::1',
        '::ffff:8.8.8.8',
        '::',
      ]) {
        expect(lan(address), isFalse, reason: address);
      }
    });

    test('mapped IPv4 clients count as their IPv4 address', () {
      expect(
        shareClientKey(InternetAddress('::ffff:192.168.1.5')),
        '192.168.1.5',
      );
      expect(shareClientKey(InternetAddress('10.0.0.9')), '10.0.0.9');
    });
  });
}
