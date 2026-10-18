import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/share_links/share_password.dart';
import 'package:whisper/share_links/share_rate_limiter.dart';
import 'package:whisper/share_links/share_routes.dart';

/// Hands out a fixed sequence, then carries on with a seeded generator.
class _ScriptedRandom implements Random {
  _ScriptedRandom(this._script);

  final List<int> _script;
  final _fallback = Random(7);
  var _index = 0;

  @override
  int nextInt(int max) => _index < _script.length
      ? _script[_index++] % max
      : _fallback.nextInt(max);

  @override
  bool nextBool() => _fallback.nextBool();

  @override
  double nextDouble() => _fallback.nextDouble();
}

void main() {
  group('route alphabet', () {
    test('has no characters that are easy to mix up', () {
      for (final c in ['0', 'o', '1', 'l', 'i']) {
        expect(ShareRoutes.alphabet.contains(c), isFalse, reason: c);
      }
      expect(ShareRoutes.alphabet.length, 31);
      expect(ShareRoutes.alphabet, matches(RegExp(r'^[a-z2-9]+$')));
      expect(ShareRoutes.alphabet.split('').toSet().length, 31);
    });

    test('generated routes are 8 characters, short ones 4', () {
      final rng = Random(1);
      for (var i = 0; i < 500; i++) {
        final route = ShareRoutes.generate(random: rng);
        expect(route.length, 8);
        expect(
          route.split('').every(ShareRoutes.alphabet.contains),
          isTrue,
          reason: route,
        );
        final short = ShareRoutes.generate(short: true, random: rng);
        expect(short.length, 4);
        expect(
          short.split('').every(ShareRoutes.alphabet.contains),
          isTrue,
          reason: short,
        );
        expect(ShareRoutes.check(route), isNull);
        expect(ShareRoutes.check(short), isNull);
      }
    });

    test('a route already taken is never handed out again', () {
      // The first four draws spell "aaaa"; it is taken, so the next draw
      // must be used instead.
      final rng = _ScriptedRandom([0, 0, 0, 0, 1, 1, 1, 1]);
      final route = ShareRoutes.generate(
        short: true,
        taken: {'aaaa'},
        random: rng,
      );
      expect(route, 'bbbb');
    });

    test('many short routes in a row do not collide', () {
      final taken = <String>{};
      final rng = Random(3);
      for (var i = 0; i < 3000; i++) {
        final route = ShareRoutes.generate(
          short: true,
          taken: taken,
          random: rng,
        );
        expect(taken.add(route), isTrue);
      }
    });
  });

  group('typed routes', () {
    test('lowercase letters, digits, - and _ from 2 to 32 characters', () {
      expect(ShareRoutes.check('ab'), isNull);
      expect(ShareRoutes.check('my-photos_2026'), isNull);
      expect(ShareRoutes.check('a' * 32), isNull);
      expect(ShareRoutes.check('a'), ShareRouteProblem.invalid);
      expect(ShareRoutes.check('a' * 33), ShareRouteProblem.invalid);
      expect(ShareRoutes.check('with space'), ShareRouteProblem.invalid);
      expect(ShareRoutes.check('dot.dot'), ShareRouteProblem.invalid);
      expect(ShareRoutes.check('slash/x'), ShareRouteProblem.invalid);
      expect(ShareRoutes.check('中文'), ShareRouteProblem.invalid);
      expect(ShareRoutes.check('Upper'), ShareRouteProblem.invalid);
      expect(ShareRoutes.check(''), ShareRouteProblem.invalid);
    });

    test('are stored lowercase without surrounding spaces', () {
      expect(ShareRoutes.normalize('  My-Photos '), 'my-photos');
      expect(ShareRoutes.check(ShareRoutes.normalize('Zip')), isNot(isNull));
    });

    test('reserved words are refused', () {
      for (final word in ['zip', 'login', 'assets', 'static', 'api']) {
        expect(
          ShareRoutes.check(word),
          ShareRouteProblem.reserved,
          reason: word,
        );
      }
      expect(ShareRoutes.check('f'), isNotNull);
      expect(ShareRoutes.check('favicon.ico'), isNotNull);
      expect(ShareRoutes.check('robots.txt'), isNotNull);
    });
  });

  group('passwords', () {
    test('PBKDF2-HMAC-SHA256 matches the RFC 7914 test vectors', () {
      String hex(List<int> bytes) =>
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(
        hex(pbkdf2HmacSha256('passwd'.codeUnits, 'salt'.codeUnits, 1, 64)),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
      expect(
        hex(pbkdf2HmacSha256('password'.codeUnits, 'salt'.codeUnits, 4096, 32)),
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
      );
    });

    test('a stored hash verifies its password and nothing else', () async {
      final hash = await SharePasswordHash.create('四月 2026', iterations: 1000);
      expect(hash.salt.length, 16);
      expect(hash.hash.length, 32);
      expect(await hash.verify('四月 2026'), isTrue);
      expect(await hash.verify('四月 2025'), isFalse);
      expect(await hash.verify(''), isFalse);
      final restored = SharePasswordHash.fromJson(hash.toJson())!;
      expect(await restored.verify('四月 2026'), isTrue);
      expect(hash.toJson().toString(), isNot(contains('四月')));
    });

    test('the default work factor is at least 100k iterations', () {
      expect(SharePasswordHash.defaultIterations, greaterThanOrEqualTo(100000));
    });

    test('cookies are bound to the link, the salt and the expiry', () {
      final signer = ShareCookieSigner(List.filled(32, 7));
      final now = DateTime(2026, 10, 17, 12);
      final token = signer.issue(linkId: 'abc', salt: [1, 2], now: now);
      expect(
        signer.verify(linkId: 'abc', salt: [1, 2], token: token, now: now),
        isTrue,
      );
      expect(
        signer.verify(linkId: 'abd', salt: [1, 2], token: token, now: now),
        isFalse,
      );
      expect(
        signer.verify(linkId: 'abc', salt: [1, 3], token: token, now: now),
        isFalse,
      );
      expect(
        signer.verify(
          linkId: 'abc',
          salt: [1, 2],
          token: token,
          now: now.add(const Duration(hours: 25)),
        ),
        isFalse,
      );
      final other = ShareCookieSigner(List.filled(32, 8));
      expect(
        other.verify(linkId: 'abc', salt: [1, 2], token: token, now: now),
        isFalse,
      );
      final forged =
          '${int.parse(token.split('.').first) + 1000}'
          '.${token.split('.').last}';
      expect(
        signer.verify(linkId: 'abc', salt: [1, 2], token: forged, now: now),
        isFalse,
      );
    });
  });

  group('rate limiter', () {
    test('ten failures in a minute block for 60 seconds', () {
      var now = DateTime(2026, 10, 17, 12);
      final limiter = ShareRateLimiter(clock: () => now);
      for (var i = 0; i < 9; i++) {
        expect(limiter.fail('10.0.0.2'), isFalse);
        now = now.add(const Duration(seconds: 1));
      }
      expect(limiter.blockedFor('10.0.0.2'), isNull);
      expect(limiter.fail('10.0.0.2'), isTrue);
      expect(limiter.blockedFor('10.0.0.2'), const Duration(seconds: 60));
      expect(limiter.blockedFor('10.0.0.3'), isNull);
      now = now.add(const Duration(seconds: 59));
      expect(limiter.blockedFor('10.0.0.2'), isNotNull);
      now = now.add(const Duration(seconds: 2));
      expect(limiter.blockedFor('10.0.0.2'), isNull);
      // Starts over after the back-off.
      expect(limiter.fail('10.0.0.2'), isFalse);
    });

    test('failures older than the window do not add up', () {
      var now = DateTime(2026, 10, 17, 12);
      final limiter = ShareRateLimiter(clock: () => now);
      for (var i = 0; i < 30; i++) {
        expect(limiter.fail('10.0.0.2'), isFalse);
        now = now.add(const Duration(seconds: 7));
      }
    });

    test('a password try is counted before it is checked', () {
      var now = DateTime(2026, 10, 17, 12);
      final limiter = ShareRateLimiter(clock: () => now);
      for (var i = 0; i < 10; i++) {
        expect(limiter.attempt('10.0.0.2'), isTrue, reason: 'try $i');
      }
      expect(limiter.attempt('10.0.0.2'), isFalse);
      expect(limiter.blockedFor('10.0.0.2'), isNotNull);
      now = now.add(const Duration(seconds: 61));
      expect(limiter.attempt('10.0.0.2'), isTrue);
      limiter.succeed('10.0.0.2');
      expect(limiter.blockedFor('10.0.0.2'), isNull);
    });

    test('a right password clears earlier mistakes', () {
      final now = DateTime(2026, 10, 17, 12);
      final limiter = ShareRateLimiter(clock: () => now);
      for (var i = 0; i < 9; i++) {
        limiter.fail('10.0.0.2');
      }
      limiter.succeed('10.0.0.2');
      expect(limiter.fail('10.0.0.2'), isFalse);
    });
  });
}
