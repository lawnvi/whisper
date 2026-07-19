import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String methodBody(String source, String start, String next) {
    final startIndex = source.indexOf(start);
    expect(startIndex, isNonNegative, reason: 'Missing method $start');
    final endIndex = source.indexOf(next, startIndex);
    expect(endIndex, isNonNegative, reason: 'Missing next method $next');
    return source.substring(startIndex, endIndex);
  }

  test('device list uses the shared signed pairing dialog', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final onPairing = methodBody(
      source,
      'void onPairing(',
      'void afterAuth(bool allow, DeviceData? deviceData)',
    );

    expect(
      source,
      contains("import 'package:whisper/widget/pairing_dialog.dart';"),
    );
    expect(onPairing, contains('showPairingDialog'));
    expect(onPairing, contains('resolve'));
    expect(onPairing, isNot(contains('showCupertinoDialog')));
    expect(source, isNot(contains('ConnectPromptRegistry')));
  });

  test('device list keeps post-auth navigation separate from pairing', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final afterAuth = methodBody(
      source,
      'void afterAuth(bool allow, DeviceData? deviceData)',
      'void onClose()',
    );

    expect(afterAuth, contains('db.upsertDevice(deviceData)'));
    expect(afterAuth, isNot(contains('resolveAndClose')));
  });
}
