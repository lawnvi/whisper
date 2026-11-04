import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/app_log.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('app-log-');
    addTearDown(() => directory.delete(recursive: true));
  });

  // People send this file to strangers. An exception's message is where file
  // names, addresses and text end up, so nothing of it may get in.
  test('an error leaves its type and code, and none of its words', () async {
    final log = AppLog()..recordError('x', StateError('/Users/me/secret.txt'));
    log.recordError(
      'y',
      const SocketException(
        'connecting to 192.168.1.2',
        osError: OSError('Connection refused', 61),
      ),
    );
    await log.start(directory);
    final text = await log.recent();

    expect(text, contains('StateError'));
    expect(text, contains('SocketException'));
    expect(text, contains('61'));
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('192.168')));
  });

  test('stays within its two files, however much is written', () async {
    final log = AppLog(maxFileBytes: 4096);
    await log.start(directory);
    for (var round = 0; round < 40; round++) {
      for (var i = 0; i < 20; i++) {
        log.write('${'x' * 80} $round $i');
      }
      await log.flush();
    }
    final text = await log.recent();
    expect(text, contains('39 19'));
    expect(text.length, lessThan(2 * 4096 + 4096));
  });
}
