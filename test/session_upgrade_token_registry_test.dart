import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

void main() {
  late int randomSeed;
  late SessionUpgradeTokenRegistry registry;
  final now = DateTime.utc(2026, 7, 10, 12);
  final mediaKey = Uint8List.fromList(
    List<int>.generate(32, (index) => index + 1),
  );

  setUp(() {
    randomSeed = 0;
    registry = SessionUpgradeTokenRegistry(
      randomBytes: (length) {
        final seed = randomSeed++;
        return Uint8List.fromList(
          List<int>.generate(length, (index) => (seed + index) & 0xff),
        );
      },
    );
  });

  test('issues a canonical single-use token bound to the complete claim', () {
    final token = registry.issue(
      route: 'audio',
      namespace: 'audio',
      sessionId: 'audio-session',
      peerId: 'peer-a',
      mediaMacKey: mediaKey,
      now: now,
    );

    expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    final claim = registry.consume(
      route: '/audio',
      sessionId: 'audio-session',
      token: token,
      now: now.add(const Duration(seconds: 29)),
    );

    expect(claim, isNotNull);
    expect(claim!.route, '/audio');
    expect(claim.namespace, 'audio');
    expect(claim.sessionId, 'audio-session');
    expect(claim.peerId, 'peer-a');
    claim.withMediaMacKey((key) {
      expect(key, orderedEquals(mediaKey));
    });
    claim.withMediaPacketContext((key, channelBinding) {
      expect(key, orderedEquals(mediaKey));
      expect(channelBinding, orderedEquals(base64Url.decode('$token=')));
    });
    expect(
      registry.consume(
        route: '/audio',
        sessionId: 'audio-session',
        token: token,
        now: now.add(const Duration(seconds: 29)),
      ),
      isNull,
    );
  });

  test(
    'namespace revocation preserves another audio type sharing the tuple',
    () {
      final direct = registry.issue(
        route: '/audio',
        namespace: 'audio',
        sessionId: 'shared-session',
        peerId: 'peer-a',
        mediaMacKey: mediaKey,
        now: now,
      );
      final group = registry.issue(
        route: '/audio',
        namespace: 'audio-group',
        sessionId: 'shared-session',
        peerId: 'peer-a',
        mediaMacKey: mediaKey,
        now: now,
      );

      registry.revoke(
        route: '/audio',
        namespace: 'audio',
        sessionId: 'shared-session',
        peerId: 'peer-a',
      );

      expect(
        registry.consume(
          route: '/audio',
          sessionId: 'shared-session',
          token: direct,
          now: now,
        ),
        isNull,
      );
      expect(
        registry
            .consume(
              route: '/audio',
              sessionId: 'shared-session',
              token: group,
              now: now,
            )
            ?.namespace,
        'audio-group',
      );
    },
  );

  test('wrong route, session, and token never consume the valid claim', () {
    final token = registry.issue(
      route: '/audio',
      sessionId: 'bound-session',
      peerId: 'peer-a',
      mediaMacKey: mediaKey,
      now: now,
    );

    expect(
      registry.consume(
        route: '/input',
        sessionId: 'bound-session',
        token: token,
        now: now,
      ),
      isNull,
    );
    expect(
      registry.consume(
        route: '/audio',
        sessionId: 'other-session',
        token: token,
        now: now,
      ),
      isNull,
    );
    expect(
      registry.consume(
        route: '/audio',
        sessionId: 'bound-session',
        token: '${token.substring(0, 42)}A',
        now: now,
      ),
      isNull,
    );
    expect(
      registry
          .consume(
            route: '/audio',
            sessionId: 'bound-session',
            token: token,
            now: now,
          )
          ?.peerId,
      'peer-a',
    );
  });

  test('expires exactly at the thirty second boundary', () {
    final token = registry.issue(
      route: '/input',
      sessionId: 'input-session',
      peerId: 'peer-a',
      mediaMacKey: mediaKey,
      now: now,
    );

    expect(
      registry.consume(
        route: '/input',
        sessionId: 'input-session',
        token: token,
        now: now.add(const Duration(seconds: 30)),
      ),
      isNull,
    );
    expect(registry.length, 0);
  });

  test('purges expired claims before enforcing the fixed capacity', () {
    registry = SessionUpgradeTokenRegistry(
      maxEntries: 2,
      randomBytes: (length) {
        final seed = randomSeed++;
        return Uint8List.fromList(
          List<int>.generate(length, (index) => (seed + index) & 0xff),
        );
      },
    );
    registry.issue(
      route: '/audio',
      sessionId: 'expired',
      peerId: 'peer-a',
      mediaMacKey: mediaKey,
      now: now,
    );
    registry.issue(
      route: '/input',
      sessionId: 'live-a',
      peerId: 'peer-b',
      mediaMacKey: mediaKey,
      now: now.add(const Duration(seconds: 20)),
    );

    registry.issue(
      route: '/audio',
      sessionId: 'live-b',
      peerId: 'peer-c',
      mediaMacKey: mediaKey,
      now: now.add(const Duration(seconds: 31)),
    );
    expect(registry.length, 2);
    expect(
      () => registry.issue(
        route: '/audio',
        sessionId: 'overflow',
        peerId: 'peer-d',
        mediaMacKey: mediaKey,
        now: now.add(const Duration(seconds: 31)),
      ),
      throwsStateError,
    );
    expect(registry.length, 2);
  });

  test(
    'peer and session revocation release claims without exposing key state',
    () {
      registry.issue(
        route: '/audio',
        sessionId: 'audio-a',
        peerId: 'peer-a',
        mediaMacKey: mediaKey,
        now: now,
      );
      final keep = registry.issue(
        route: '/input',
        sessionId: 'input-b',
        peerId: 'peer-b',
        mediaMacKey: mediaKey,
        now: now,
      );

      registry.clearPeer('peer-a');
      expect(registry.length, 1);
      final claim = registry.consume(
        route: '/input',
        sessionId: 'input-b',
        token: keep,
        now: now,
      )!;
      late Uint8List scopedKey;
      claim.withMediaMacKey((key) {
        scopedKey = key;
        key[0] ^= 0xff;
      });
      expect(scopedKey, everyElement(0));
      claim.withMediaMacKey((key) {
        expect(key, orderedEquals(mediaKey));
      });
    },
  );

  test(
    'constant-time byte comparison covers early, late, and length mismatch',
    () {
      final baseline = Uint8List.fromList(<int>[1, 2, 3, 4]);
      expect(constantTimeBytesEqual(baseline, baseline), isTrue);
      expect(
        constantTimeBytesEqual(baseline, Uint8List.fromList(<int>[9, 2, 3, 4])),
        isFalse,
      );
      expect(
        constantTimeBytesEqual(baseline, Uint8List.fromList(<int>[1, 2, 3, 9])),
        isFalse,
      );
      expect(
        constantTimeBytesEqual(baseline, Uint8List.fromList(<int>[1, 2, 3])),
        isFalse,
      );
    },
  );

  test('claim key material is unavailable after explicit destruction', () {
    final claim = SessionUpgradeClaim(
      route: '/audio',
      namespace: 'audio',
      sessionId: 'session-a',
      peerId: 'peer-a',
      mediaMacKey: Uint8List(32),
      channelBinding: Uint8List(32),
    );

    claim.destroy();
    claim.destroy();

    expect(claim.isDestroyed, isTrue);
    expect(() => claim.withMediaMacKey<void>((_) {}), throwsStateError);
    expect(
      () => claim.withMediaPacketContext<void>((_, __) {}),
      throwsStateError,
    );
  });
}
