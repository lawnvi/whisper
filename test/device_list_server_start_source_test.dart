import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/device_list_rules.dart';

import 'support/source_reading.dart';

void main() {
  group('refreshing the device list', () {
    // Starting the server closes every session and each close refreshes the
    // list. Deciding from the device, which only the end of a refresh sets,
    // restarted the server hundreds of times after launch.
    test('starts the server once, however many refreshes follow', () {
      final start = DeviceListServerStart();
      expect(start.shouldStart(isFirst: true, port: 10002), isTrue);
      for (var i = 0; i < 100; i++) {
        expect(start.shouldStart(isFirst: false, port: 10002), isFalse);
      }
    });

    test('restarts it when the port changes, then settles again', () {
      final start = DeviceListServerStart();
      start.shouldStart(isFirst: true, port: 10002);
      expect(start.shouldStart(isFirst: false, port: 10003), isTrue);
      expect(start.shouldStart(isFirst: false, port: 10003), isFalse);
    });

    test('a refresh before any start still starts it', () {
      expect(
        DeviceListServerStart().shouldStart(isFirst: false, port: 10002),
        isTrue,
      );
    });

    test(
      'decides before waiting for the start, so a refresh it causes sees it',
      () {
        final refresh = memberSource(
          deviceListSource(),
          'Future<void> _refreshDevice',
        );
        final decision = refresh.indexOf('_serverStart.shouldStart(');
        expect(decision, isNot(-1));
        expect(
          refresh.indexOf('await _startServer(port: temp.port);'),
          greaterThan(decision),
        );
      },
    );
  });
}
