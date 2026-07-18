import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('QR pairing pins both peer id and public-key hash', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains('PairingQrScreen('));
    expect(source, contains('peerId: invite.peerId'));
    expect(source, contains('publicKeyHash: invite.publicKeyHash'));
    expect(source, contains('expectedPeerId: peerId ??'));
    expect(source, contains('expectedPublicKeyHash: publicKeyHash ??'));
  });

  test('invalid local QR host is diagnosed as a Wi-Fi problem', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains('error.reason == PairingInviteError.invalidHost'));
    expect(source, contains('? ConnectionDiagnosticStage.wifi'));
  });

  test('mobile runners declare camera access for QR scanning', () {
    final androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final iosInfo = File('ios/Runner/Info.plist').readAsStringSync();

    expect(androidManifest, contains('android.permission.CAMERA'));
    expect(iosInfo, contains('NSCameraUsageDescription'));
  });
}
