import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('refreshing the device list starts the server only once', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final refresh = source.substring(
      source.indexOf('Future<void> _refreshDevice'),
      source.indexOf('ChatSessionPreviewStrings _sessionPreviewStrings'),
    );
    // Starting the server closes every session and each close refreshes the
    // list. Deciding from `device`, which only the end of a refresh sets,
    // restarted the server hundreds of times after launch.
    final decision = refresh.indexOf(
      'if (isFirst || _serverStartPort != temp.port) {',
    );
    expect(decision, isNot(-1));
    final remember = refresh.indexOf('_serverStartPort = temp.port;', decision);
    final start = refresh.indexOf(
      'await _startServer(port: temp.port);',
      decision,
    );
    expect(remember, greaterThan(decision));
    expect(start, greaterThan(remember));
    expect(refresh, isNot(contains('device?.port != temp.port')));
  });
}
