import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/staggered_dialer.dart';
import 'package:whisper/state/network_change_watcher.dart';
import 'package:whisper/state/peer_endpoint.dart';

void main() {
  group('dialStaggered', () {
    test(
      'staggers launch, returns first winner, closes late losers, and reports remaining candidates',
      () async {
        final ep1 = PeerEndpoint.loopbackForTesting(port: 10011);
        final ep2 = PeerEndpoint.loopbackForTesting(port: 10012);
        final ep3 = PeerEndpoint.loopbackForTesting(port: 10013);
        final started = <int>[];
        final closed = <String>[];
        final slowPrimary = Completer<String>();

        final win = await dialStaggered<String>(
          endpoints: [ep1, ep2, ep3],
          stagger: const Duration(milliseconds: 25),
          dial: (ep) {
            started.add(ep.port);
            if (ep == ep1) return slowPrimary.future;
            if (ep == ep2) return Future<String>.value('conn-2');
            return Completer<String>().future;
          },
          close: (conn) async => closed.add(conn),
        );

        expect(win.endpoint, ep2);
        expect(win.connection, 'conn-2');
        expect(win.remaining, [ep1, ep3]);
        expect(started, [10011, 10012]);

        // Late-settling primary is closed automatically and never leaks.
        slowPrimary.complete('conn-1');
        await pumpEventQueue();
        expect(closed, ['conn-1']);
      },
    );

    test(
      'fast failure immediately launches next candidate without waiting stagger',
      () async {
        final ep1 = PeerEndpoint.loopbackForTesting(port: 10021);
        final ep2 = PeerEndpoint.loopbackForTesting(port: 10022);
        final watch = Stopwatch()..start();

        final win = await dialStaggered<String>(
          endpoints: [ep1, ep2],
          stagger: const Duration(seconds: 5),
          dial: (ep) async {
            if (ep == ep1) throw const SocketException('refused');
            return 'conn-2';
          },
          close: (_) async {},
        );

        expect(win.endpoint, ep2);
        expect(win.remaining, isEmpty);
        expect(watch.elapsedMilliseconds, lessThan(500));
      },
    );

    test(
      'rethrows primary error when all candidates fail and respects cancellation',
      () async {
        final ep1 = PeerEndpoint.loopbackForTesting(port: 10031);
        final ep2 = PeerEndpoint.loopbackForTesting(port: 10032);

        await expectLater(
          dialStaggered<String>(
            endpoints: [ep1, ep2],
            stagger: const Duration(milliseconds: 10),
            dial: (ep) async {
              if (ep == ep1) throw const SocketException('primary refused');
              throw TimeoutException('secondary timed out');
            },
            close: (_) async {},
          ),
          throwsA(isA<SocketException>()),
        );

        var cancelled = false;
        final gate = Completer<String>();
        final closed = <String>[];
        final future = dialStaggered<String>(
          endpoints: [ep1, ep2],
          stagger: const Duration(milliseconds: 20),
          isCancelled: () => cancelled,
          dial: (_) => gate.future,
          close: (c) async => closed.add(c),
        );
        cancelled = true;
        gate.complete('late');
        await expectLater(future, throwsA(isA<StaggeredDialCancelled>()));
        await pumpEventQueue();
        expect(closed, ['late']);
      },
    );
  });

  group('NetworkChangeWatcher', () {
    test(
      'detects fingerprint changes with debounce and supports background/resume',
      () async {
        var current = <String>{'en0=192.168.1.10'};
        final notifications = <Set<String>>[];
        final watcher = NetworkChangeWatcher(
          foregroundInterval: const Duration(seconds: 60),
          backgroundInterval: const Duration(seconds: 120),
          debounce: const Duration(milliseconds: 25),
          fingerprintProvider: () async => current,
          onNetworkChanged: (fp) => notifications.add(fp),
        );
        addTearDown(watcher.stop);

        await watcher.start();
        await watcher.checkNow();
        expect(notifications, isEmpty);

        // Rapid churn collapses into one debounced notification.
        current = <String>{'en0=192.168.1.11'};
        await watcher.checkNow();
        current = <String>{'en0=192.168.1.12'};
        await watcher.checkNow();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(notifications, hasLength(1));
        expect(notifications.single, {'en0=192.168.1.12'});

        // Returning from background triggers an immediate sample.
        watcher.setBackgrounded(true);
        expect(watcher.isBackgrounded, isTrue);
        current = <String>{'en1=10.0.0.5'};
        watcher.setBackgrounded(false);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(notifications, hasLength(2));
        expect(notifications.last, {'en1=10.0.0.5'});
      },
    );
  });
}
