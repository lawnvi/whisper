import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/share_links/share_lan.dart';
import 'package:whisper/share_links/share_range.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/share_links/share_server.dart';

void main() {
  group('Range', () {
    test('no header, an empty file or another unit: the whole file', () {
      expect(parseShareRange(null, 1000), isA<ShareRangeWhole>());
      expect(parseShareRange('', 1000), isA<ShareRangeWhole>());
      expect(parseShareRange('bytes=0-10', 0), isA<ShareRangeWhole>());
      expect(parseShareRange('items=0-10', 1000), isA<ShareRangeWhole>());
      expect(parseShareRange('bytes=0-1,5-9', 1000), isA<ShareRangeWhole>());
    });

    test('bytes=0- is everything as a part (resuming from the start)', () {
      expect(parseShareRange('bytes=0-', 1000), const ShareRangePart(0, 999));
    });

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

    test('Accept-Language picks the most wanted supported language', () {
      expect(shareLocaleFor('zh-CN,zh;q=0.9,en;q=0.8').languageCode, 'zh');
      expect(shareLocaleFor('fr-FR,es;q=0.8,en;q=0.5').languageCode, 'es');
      expect(shareLocaleFor('en;q=0.5,zh-TW;q=0.9').languageCode, 'zh');
      expect(shareLocaleFor('de, fr').languageCode, 'en');
      expect(shareLocaleFor(null).languageCode, 'en');
      expect(shareLocaleFor('es;q=0, en').languageCode, 'en');
    });

    test('cookies are read leniently', () {
      expect(shareCookieValue(['a=1; wsl_x="tok.en"; b=2'], 'wsl_x'), 'tok.en');
      expect(shareCookieValue(['broken; wsl_x=v'], 'wsl_x'), 'v');
      expect(shareCookieValue(null, 'wsl_x'), isNull);
      expect(shareCookieValue(['wsl_y=1'], 'wsl_x'), isNull);
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

  group('text preview', () {
    late Directory temp;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('share_snippet_');
    });
    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('short text comes back whole, without a byte-order mark', () async {
      final file = File(p.join(temp.path, 'a.txt'));
      await file.writeAsString('\uFEFF你好 world');
      final snippet = await shareTextSnippet(file.path);
      expect(snippet!.$1, '你好 world');
      expect(snippet.$2, isFalse);
    });

    test('long text is cut, never in the middle of a character', () async {
      final file = File(p.join(temp.path, 'b.txt'));
      await file.writeAsString('汉' * 100); // 3 bytes each
      final snippet = await shareTextSnippet(file.path, limit: 31);
      expect(snippet!.$2, isTrue);
      expect(snippet.$1, '汉' * 10);
    });

    test('anything with a NUL near the start is not text', () async {
      final file = File(p.join(temp.path, 'c.bin'));
      await file.writeAsBytes([0x50, 0x4b, 0x03, 0x04, 0, 0, 1]);
      expect(await shareTextSnippet(file.path), isNull);
      expect(await shareTextSnippet(p.join(temp.path, 'missing')), isNull);
    });
  });
}
