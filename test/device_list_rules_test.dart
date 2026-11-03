import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/state/device_list_rules.dart';

const _stored = DeviceData(
  id: 7,
  uid: 'peer',
  identityPublicKey: 'pinned-key',
  name: 'Stored name',
  host: '10.0.0.1',
  port: 1111,
  password: 'secret',
  platform: 'macos',
  isServer: true,
  online: true,
  clipboard: true,
  auth: true,
  lastTime: 1,
  around: false,
);

const _discovered = DeviceData(
  id: 0,
  uid: 'peer',
  identityPublicKey: 'claimed-key',
  name: 'Fresh name',
  host: '10.0.0.2',
  port: 2222,
  password: '',
  platform: 'windows',
  isServer: false,
  online: false,
  clipboard: false,
  auth: false,
  lastTime: 2,
  around: true,
);

void main() {
  group('merging what discovery sees over what is stored', () {
    test('a device never stored is taken as discovered', () {
      expect(mergeStoredDeviceWithDiscovery(null, _discovered), _discovered);
    });

    test('where it is and what it is called come from discovery', () {
      final merged = mergeStoredDeviceWithDiscovery(_stored, _discovered);
      expect(merged.host, '10.0.0.2');
      expect(merged.port, 2222);
      expect(merged.name, 'Fresh name');
      expect(merged.platform, 'windows');
      expect(merged.lastTime, 2);
      expect(merged.around, isTrue);
    });

    test('an empty discovery does not blank what is known', () {
      final merged = mergeStoredDeviceWithDiscovery(
        _stored,
        _discovered.copyWith(name: '', host: '', platform: ''),
      );
      expect(merged.name, 'Stored name');
      expect(merged.host, '10.0.0.1');
      expect(merged.platform, 'macos');
    });

    test('trust and the pinned identity stay the stored ones', () {
      final merged = mergeStoredDeviceWithDiscovery(_stored, _discovered);
      expect(merged.identityPublicKey, 'pinned-key');
      expect(merged.auth, isTrue);
      expect(merged.clipboard, isTrue);
      expect(merged.password, 'secret');
      expect(merged.id, 7);
      expect(merged.isServer, isTrue);
      expect(merged.online, isTrue);
    });
  });

  group('the identity hash a device is trusted under', () {
    // Any base64url value of a key's length hashes; a broken one does not.
    final key = 'A' * 43;

    String? hash(
      List<DeviceData> devices, {
      bool trusted = true,
      String peerId = 'peer',
    }) => trustedDeviceIdentityHash(
      devices: devices,
      peerId: peerId,
      isLocallyTrusted: (_) => trusted,
    );

    test('a trusted device with an identity has one', () {
      final device = _stored.copyWith(identityPublicKey: key);
      expect(hash([device]), identityPublicKeyHash(key));
    });

    test('nothing without trust, an identity, or a match', () {
      final device = _stored.copyWith(identityPublicKey: key);
      expect(hash([device.copyWith(auth: false)]), isNull);
      expect(hash([device.copyWith(identityPublicKey: '')]), isNull);
      expect(hash([device], trusted: false), isNull);
      expect(hash([device], peerId: 'someone else'), isNull);
    });

    test('a malformed identity is not trusted, and does not throw', () {
      expect(hash([_stored.copyWith(identityPublicKey: 'not a key')]), isNull);
    });
  });

  group('whether keyboard and mouse sharing is really going on', () {
    bool live({
      RemoteInputWorkspaceSnapshot workspace =
          const RemoteInputWorkspaceSnapshot.idle(),
      RemoteInputRuntimeState legacy = const RemoteInputRuntimeState.idle(),
      bool manual = false,
      bool connected = true,
    }) => isRemoteInputSessionLive(
      workspace: workspace,
      legacy: legacy,
      legacyIsManual: manual,
      isConnected: (_) => connected,
    );

    const session = RemoteInputRuntimeState(
      status: RemoteInputRuntimeStatus.active,
      role: RemoteInputRuntimeRole.source,
      peerId: 'peer',
    );

    test('idle is not', () => expect(live(), isFalse));

    test('a session with its peer still connected is', () {
      expect(live(legacy: session), isTrue);
    });

    test('a stale session whose peer has left is not', () {
      expect(live(legacy: session, connected: false), isFalse);
    });

    test('a manual session from a phone does not light the toolbar', () {
      expect(live(legacy: session, manual: true), isFalse);
    });

    test('a failed session is not', () {
      expect(
        live(
          legacy: const RemoteInputRuntimeState(
            status: RemoteInputRuntimeStatus.failed,
            role: RemoteInputRuntimeRole.source,
            peerId: 'peer',
          ),
        ),
        isFalse,
      );
    });

    RemoteInputWorkspaceSnapshot controller(
      RemoteInputWorkspaceTargetStatus status,
    ) => RemoteInputWorkspaceSnapshot(
      role: RemoteInputWorkspaceRole.controller,
      status: RemoteInputWorkspaceStatus.active,
      targets: {
        'peer': RemoteInputWorkspaceTargetSnapshot(
          peerId: 'peer',
          peerName: 'iMac',
          sessionId: 's',
          status: status,
        ),
      },
    );

    test('a workspace needs a target that is really connected', () {
      expect(
        live(workspace: controller(RemoteInputWorkspaceTargetStatus.connected)),
        isTrue,
      );
      expect(
        live(workspace: controller(RemoteInputWorkspaceTargetStatus.failed)),
        isFalse,
      );
    });
  });
}
