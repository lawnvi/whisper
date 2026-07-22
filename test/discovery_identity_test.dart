import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/state/discovery_identity.dart';

void main() {
  test('derives the canonical public-key hash and private instance name',
      () async {
    final identity = await DeviceIdentity.fromSeed(
      Uint8List.fromList(List<int>.generate(32, (index) => index)),
    );

    final discovery =
        DiscoveryIdentity.fromPublicKey(identity.publicKeyBase64Url);

    final expectedPkh = identityPublicKeyHash(identity.publicKeyBase64Url);
    expect(DiscoveryIdentity.protocolVersion, '9');
    expect(discovery.publicKeyHash, expectedPkh);
    expect(discovery.pkh, expectedPkh);
    expect(discovery.publicKeyHash, hasLength(43));
    expect(discovery.serviceInstanceName,
        'whisper-${expectedPkh.substring(0, 8)}');
    expect(discovery.instanceName, discovery.serviceInstanceName);
    expect(discovery.txt, <String, String>{
      'v': DiscoveryIdentity.protocolVersion,
      'pkh': expectedPkh,
    });
  });

  test('is deterministic and exposes no profile or device identifiers',
      () async {
    final identity = await DeviceIdentity.fromSeed(Uint8List(32));

    final first = DiscoveryIdentity.fromPublicKey(identity.publicKeyBase64Url);
    final second = DiscoveryIdentity.fromPublicKey(identity.publicKeyBase64Url);

    expect(first, second);
    expect(first.txt.keys, unorderedEquals(<String>['v', 'pkh']));
    expect(() => first.txt['uid'] = 'device-id', throwsUnsupportedError);
    expect(
      first.txt.keys,
      isNot(containsAll(<String>['uid', 'name', 'platform', 'host', 'port'])),
    );
  });

  test('rejects non-canonical identity public keys', () {
    expect(
      () => DiscoveryIdentity.fromPublicKey('not-a-public-key'),
      throwsFormatException,
    );
  });
}
