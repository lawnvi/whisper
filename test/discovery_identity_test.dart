import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/state/auto_connect_planner.dart';
import 'package:whisper/state/connection_models.dart';
import 'package:whisper/state/discovery_identity.dart';

void main() {
  test(
    'derives the canonical public-key hash and private instance name',
    () async {
      final identity = await DeviceIdentity.fromSeed(
        Uint8List.fromList(List<int>.generate(32, (index) => index)),
      );

      final discovery = DiscoveryIdentity.fromPublicKey(
        identity.publicKeyBase64Url,
      );

      final expectedPkh = identityPublicKeyHash(identity.publicKeyBase64Url);
      expect(
        DiscoveryIdentity.protocolVersion,
        '${PeerSocketSession.protocolVersion}',
      );
      expect(DiscoveryIdentity.protocolVersion, '16');
      expect(discovery.publicKeyHash, expectedPkh);
      expect(discovery.pkh, expectedPkh);
      expect(discovery.publicKeyHash, hasLength(43));
      expect(
        discovery.serviceInstanceName,
        'whisper-${expectedPkh.substring(0, 8)}',
      );
      expect(discovery.instanceName, discovery.serviceInstanceName);
      expect(discovery.txt, <String, String>{
        'v': DiscoveryIdentity.protocolVersion,
        'pkh': expectedPkh,
      });

      final attrs = discovery.buildBroadcastAttributes(
        host: '192.168.1.20',
        port: 10002,
        name: 'MacBook',
        platform: 'macos',
        uid: 'peer-1',
      );
      expect(attrs, <String, String>{
        'v': '16',
        'pkh': expectedPkh,
        'host': '192.168.1.20',
        'port': '10002',
        'name': 'MacBook',
        'platform': 'macos',
        'uid': 'peer-1',
      });
    },
  );

  test(
    'is deterministic and exposes no profile or device identifiers in txt',
    () async {
      final identity = await DeviceIdentity.fromSeed(Uint8List(32));

      final first = DiscoveryIdentity.fromPublicKey(
        identity.publicKeyBase64Url,
      );
      final second = DiscoveryIdentity.fromPublicKey(
        identity.publicKeyBase64Url,
      );

      expect(first, second);
      expect(first.txt.keys, unorderedEquals(<String>['v', 'pkh']));
      expect(() => first.txt['uid'] = 'device-id', throwsUnsupportedError);
      expect(
        first.txt.keys,
        isNot(containsAll(<String>['uid', 'name', 'platform', 'host', 'port'])),
      );
    },
  );

  test(
    'allowsAutoConnect filters incompatible versions and mismatched pkh',
    () async {
      final stored = await DeviceIdentity.fromSeed(
        Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      );
      final other = await DeviceIdentity.fromSeed(
        Uint8List.fromList(List<int>.generate(32, (i) => i + 9)),
      );
      final storedPkh = identityPublicKeyHash(stored.publicKeyBase64Url);
      final otherPkh = identityPublicKeyHash(other.publicKeyBase64Url);

      final cases =
          <
            ({
              String name,
              Map<String, String> attrs,
              String? storedKey,
              bool expected,
            })
          >[
            (
              name: 'matching v=16 and matching pkh',
              attrs: {'v': '16', 'pkh': storedPkh},
              storedKey: stored.publicKeyBase64Url,
              expected: true,
            ),
            (
              name: 'absent pkh and v remains unaffected',
              attrs: {'name': 'Old-ish'},
              storedKey: stored.publicKeyBase64Url,
              expected: true,
            ),
            (
              name: 'older incompatible version skips auto-connect',
              attrs: {'v': '15', 'pkh': storedPkh},
              storedKey: stored.publicKeyBase64Url,
              expected: false,
            ),
            (
              name: 'newer incompatible version skips auto-connect',
              attrs: {'v': '17', 'pkh': storedPkh},
              storedKey: stored.publicKeyBase64Url,
              expected: false,
            ),
            (
              name: 'paired device with mismatched pkh skips auto-connect',
              attrs: {'v': '16', 'pkh': otherPkh},
              storedKey: stored.publicKeyBase64Url,
              expected: false,
            ),
            (
              name: 'paired device with malformed pkh skips auto-connect',
              attrs: {'v': '16', 'pkh': 'bad-hash'},
              storedKey: stored.publicKeyBase64Url,
              expected: false,
            ),
            (
              name: 'unpaired device with valid v=16 is not blocked by pkh',
              attrs: {'v': '16', 'pkh': otherPkh},
              storedKey: '',
              expected: true,
            ),
          ];

      for (final c in cases) {
        expect(
          DiscoveryIdentity.allowsAutoConnect(
            attributes: c.attrs,
            storedIdentityPublicKey: c.storedKey,
          ),
          c.expected,
          reason: c.name,
        );
      }

      // AutoConnectPlanner skips candidates marked autoConnectEligible: false.
      final now = DateTime(2026);
      final blocked = DevicePresence(
        peerId: 'peer-mismatch',
        name: 'Mismatch',
        host: '192.168.1.30',
        port: 10002,
        platform: 'macos',
        state: ConnectionLifecycleState.candidate,
        discovered: true,
        locallyTrusted: true,
        remotelyTrusted: true,
        lastSeenAt: now.add(const Duration(seconds: 5)),
        autoConnectEligible: false,
      );
      final ok = DevicePresence(
        peerId: 'peer-ok',
        name: 'Ok',
        host: '192.168.1.31',
        port: 10002,
        platform: 'macos',
        state: ConnectionLifecycleState.candidate,
        discovered: true,
        locallyTrusted: true,
        remotelyTrusted: true,
        lastSeenAt: now,
        autoConnectEligible: true,
      );
      expect(
        AutoConnectPlanner.selectCandidate(
          autoConnectEnabled: true,
          lastManualPeerId: blocked.peerId,
          candidates: [blocked, ok],
        )?.peerId,
        ok.peerId,
      );
    },
  );

  test('rejects non-canonical identity public keys', () {
    expect(
      () => DiscoveryIdentity.fromPublicKey('not-a-public-key'),
      throwsFormatException,
    );
  });
}
