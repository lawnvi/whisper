import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/quick_send_identity_gate.dart';

void main() {
  test(
    'quick-send identity gate requires the trusted session and pin to match',
    () async {
      final identityA = await DeviceIdentity.fromSeed(Uint8List(32));
      final identityB = await DeviceIdentity.fromSeed(
        Uint8List(32)..fillRange(0, 32, 1),
      );
      final hashA = identityPublicKeyHash(identityA.publicKeyBase64Url);

      expect(
        matchesExpectedQuickSendIdentity(
          expectedPublicKeyHash: hashA,
          authenticatedIdentityPublicKey: identityA.publicKeyBase64Url,
          storedTrusted: true,
          storedIdentityPublicKey: identityA.publicKeyBase64Url,
        ),
        isTrue,
      );
      for (final mismatch in <({String session, bool trusted, String stored})>[
        (
          session: identityB.publicKeyBase64Url,
          trusted: true,
          stored: identityA.publicKeyBase64Url,
        ),
        (
          session: identityA.publicKeyBase64Url,
          trusted: false,
          stored: identityA.publicKeyBase64Url,
        ),
        (
          session: identityA.publicKeyBase64Url,
          trusted: true,
          stored: identityB.publicKeyBase64Url,
        ),
      ]) {
        expect(
          matchesExpectedQuickSendIdentity(
            expectedPublicKeyHash: hashA,
            authenticatedIdentityPublicKey: mismatch.session,
            storedTrusted: mismatch.trusted,
            storedIdentityPublicKey: mismatch.stored,
          ),
          isFalse,
        );
      }
    },
  );

  // 'discovery merging retains the durable pinned identity' is in
  // device_list_rules_test.dart.
}
