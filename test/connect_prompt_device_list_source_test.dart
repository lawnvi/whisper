import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_reading.dart';

void main() {
  test('device list uses the shared signed pairing dialog', () {
    final source = deviceListSource();
    final onPairing =
        memberSource(source, 'void onPairing(') +
        memberSource(source, 'Future<void> _presentPairingRequest(');

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
    final source = deviceListSource();
    final afterAuth = memberSource(
      source,
      'void afterAuth(bool allow, DeviceData? deviceData)',
    );

    expect(afterAuth, contains('db.upsertDevice(deviceData)'));
    expect(afterAuth, isNot(contains('resolveAndClose')));
  });
}
