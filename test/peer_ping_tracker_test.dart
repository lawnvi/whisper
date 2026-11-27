import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/peer_ping_tracker.dart';
import 'package:whisper/state/peer_link_quality.dart';

void main() {
  group('PeerPingTracker', () {
    test(
      'measures monotonic RTT and ignores unknown or malformed pongs',
      () async {
        var clockUs = 10_000;
        final tracker = PeerPingTracker(nowUs: () => clockUs);

        final ping = tracker.startPing('peer-a');
        expect(tracker.buildPongPayload(ping.payload), ping.payload);
        expect(tracker.buildPongPayload('not-json'), isNull);
        expect(tracker.buildPongPayload('{"seq":0}'), isNull);

        clockUs += 18_500;
        expect(tracker.completePong('peer-a', '{"seq":999}'), isNull);
        final rtt = tracker.completePong('peer-a', ping.payload);
        expect(rtt, const Duration(microseconds: 18_500));
        expect(await ping.rtt, const Duration(microseconds: 18_500));
        expect(
          tracker.lastRttFor('peer-a'),
          const Duration(microseconds: 18_500),
        );
      },
    );

    test(
      'times out pending ping to null and cancels cleanly on clearPeer',
      () async {
        final tracker = PeerPingTracker();

        final timedOut = tracker.startPing(
          'peer-a',
          timeout: const Duration(milliseconds: 20),
        );
        expect(await timedOut.rtt, isNull);

        final cleared = tracker.startPing(
          'peer-b',
          timeout: const Duration(seconds: 5),
        );
        tracker.clearPeer('peer-b');
        expect(await cleared.rtt, isNull);
      },
    );

    test(
      'dead-peer silence check uses 45s zero-inbound only, never RTT magnitude',
      () async {
        var clockUs = 0;
        final tracker = PeerPingTracker(nowUs: () => clockUs);
        tracker.noteInboundActivity('peer-a');

        // High RTT (e.g. 8s under heavy inbound queue load) does not trigger dead-peer.
        final ping = tracker.startPing(
          'peer-a',
          timeout: const Duration(seconds: 30),
        );
        clockUs += const Duration(seconds: 8).inMicroseconds;
        tracker.noteInboundActivity('peer-a');
        expect(
          tracker.completePong('peer-a', ping.payload),
          const Duration(seconds: 8),
        );
        expect(tracker.isSilentPastLimit('peer-a'), isFalse);

        // 44.9s of silence is still alive; 45s triggers silence limit.
        clockUs += const Duration(milliseconds: 44_900).inMicroseconds;
        expect(tracker.isSilentPastLimit('peer-a'), isFalse);

        clockUs += const Duration(milliseconds: 100).inMicroseconds;
        expect(tracker.isSilentPastLimit('peer-a'), isTrue);

        // Any inbound frame resets the silence window.
        tracker.noteInboundActivity('peer-a');
        expect(tracker.isSilentPastLimit('peer-a'), isFalse);
      },
    );

    test('keepalive invokes onSilent once silence limit is reached', () async {
      var clockUs = 0;
      final tracker = PeerPingTracker(
        nowUs: () => clockUs,
        silenceLimit: const Duration(seconds: 45),
      );
      final sentPayloads = <String>[];
      final silentCalled = Completer<void>();

      tracker.startKeepalive(
        token: Object(),
        peerId: 'peer-a',
        interval: const Duration(milliseconds: 15),
        sendPing: (payload) async {
          sentPayloads.add(payload);
          return true;
        },
        onSilent: () async {
          if (!silentCalled.isCompleted) silentCalled.complete();
        },
      );
      addTearDown(tracker.clearAll);

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(sentPayloads, isNotEmpty);
      expect(silentCalled.isCompleted, isFalse);

      clockUs += const Duration(seconds: 46).inMicroseconds;
      await silentCalled.future.timeout(const Duration(seconds: 1));
    });
  });

  group('PeerLinkQuality with /chat measure callback', () {
    test(
      'uses measure callback instead of TCP connect and grades link',
      () async {
        var tcpAttempts = 0;
        var probeIndex = 0;
        const samples = <Duration?>[
          Duration(milliseconds: 8),
          Duration(milliseconds: 10),
          Duration(milliseconds: 9),
        ];
        final quality = PeerLinkQuality(
          host: '127.0.0.1',
          port: 1,
          every: const Duration(milliseconds: 10),
          measure: () async => samples[probeIndex++ % samples.length],
          reach: (_, _) async {
            tcpAttempts += 1;
          },
        );
        addTearDown(quality.dispose);

        quality.start();
        for (var i = 0; i < 50 && quality.tries.length < 3; i += 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        quality.stop();

        expect(tcpAttempts, 0);
        expect(quality.tries.length, greaterThanOrEqualTo(3));
        expect(quality.grade, LinkGrade.good);
      },
    );
  });
}
