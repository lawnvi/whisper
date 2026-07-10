import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/discovery_observation_tracker.dart';

String _pkh(int seed) =>
    base64Url.encode(Uint8List(32)..fillRange(0, 32, seed)).replaceAll('=', '');

Map<String, String> _txt(String pkh) => <String, String>{
      'v': '5',
      'pkh': pkh,
    };

void main() {
  test('accepts only strict private TXT and resolved SRV endpoints', () {
    final tracker = DiscoveryObservationTracker()..start();
    final handle = tracker.found(
      serviceName: 'whisper-00000000',
      serviceType: '_whisper._tcp',
    );

    expect(
      tracker.resolve(
        handle,
        attributes: <String, String>{..._txt(_pkh(1)), 'uid': 'leak'},
        host: 'peer.local',
        port: 10002,
      ),
      isFalse,
    );
    expect(
      tracker.resolve(
        handle,
        attributes: _txt(_pkh(1)),
        host: '8.8.8.8',
        port: 10002,
      ),
      isFalse,
    );
    expect(
      tracker.resolve(
        handle,
        attributes: _txt(_pkh(1)),
        host: 'peer.local',
        port: 10002,
      ),
      isTrue,
    );
    expect(tracker.candidates.single.publicKeyHash, _pkh(1));
    expect(tracker.candidates.single.endpoint.host, 'peer.local');
    expect(tracker.candidates.single.endpoint.port, 10002);
  });

  test('late resolve cannot revive a lost observation or old generation', () {
    final tracker = DiscoveryObservationTracker()..start();
    final lost = tracker.found(
      serviceName: 'whisper-lost',
      serviceType: '_whisper._tcp',
    );
    expect(tracker.lost(serviceName: 'whisper-lost'), isTrue);
    expect(
      tracker.resolve(
        lost,
        attributes: _txt(_pkh(2)),
        host: 'lost.local',
        port: 10002,
      ),
      isFalse,
    );

    final staleGeneration = tracker.found(
      serviceName: 'whisper-stale',
      serviceType: '_whisper._tcp',
    );
    tracker.start();
    expect(
      tracker.resolve(
        staleGeneration,
        attributes: _txt(_pkh(3)),
        host: 'stale.local',
        port: 10002,
      ),
      isFalse,
    );
    expect(tracker.candidates, isEmpty);
  });

  test('raw loss removes one observation without dropping another endpoint',
      () {
    final tracker = DiscoveryObservationTracker()..start();
    final first = tracker.found(
      serviceName: 'whisper-shared',
      serviceType: '_whisper._tcp',
    );
    final second = tracker.found(
      serviceName: 'whisper-shared',
      serviceType: '_whisper._tcp',
    );
    expect(
      tracker.resolve(
        first,
        attributes: _txt(_pkh(4)),
        host: '192.168.1.20',
        port: 10002,
      ),
      isTrue,
    );
    expect(
      tracker.resolve(
        second,
        attributes: _txt(_pkh(4)),
        host: '192.168.1.21',
        port: 10003,
      ),
      isTrue,
    );
    expect(tracker.candidates.single.endpoints, hasLength(2));

    expect(tracker.lost(serviceName: 'whisper-shared'), isTrue);
    expect(tracker.candidates, hasLength(1));
    expect(tracker.candidates.single.endpoints, hasLength(1));

    expect(tracker.lost(serviceName: 'whisper-shared'), isTrue);
    expect(tracker.candidates, isEmpty);
  });

  test('stop invalidates handles and clears every candidate', () {
    final tracker = DiscoveryObservationTracker()..start();
    final handle = tracker.found(
      serviceName: 'whisper-stop',
      serviceType: '_whisper._tcp',
    );
    tracker.resolve(
      handle,
      attributes: _txt(_pkh(5)),
      host: 'stop.local',
      port: 10002,
    );

    tracker.stop();

    expect(tracker.candidates, isEmpty);
    expect(
      tracker.resolve(
        handle,
        attributes: _txt(_pkh(5)),
        host: 'stop.local',
        port: 10002,
      ),
      isFalse,
    );
  });
}
