import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/connection_models.dart';
import 'package:whisper/state/device_workspace_state.dart';

DeviceData buildDevice(
  String uid, {
  String name = 'Device',
  bool auth = false,
  bool around = false,
}) {
  return DeviceData(
    id: 0,
    uid: uid,
    name: name,
    host: '192.168.1.10',
    port: 10002,
    password: '',
    platform: 'linux',
    isServer: false,
    online: false,
    clipboard: false,
    auth: auth,
    lastTime: 1,
    around: around,
  );
}

void main() {
  test('builds grouped sections for connected, trusted, nearby, and history',
      () {
    final state = DeviceWorkspaceStateBuilder.build(
      devices: [
        buildDevice('connected', name: 'Connected'),
        buildDevice('trusted', name: 'Trusted', auth: true),
        buildDevice('nearby', name: 'Nearby', around: true),
        buildDevice('history', name: 'History'),
      ],
      presences: {
        'connected': DevicePresence(
          peerId: 'connected',
          name: 'Connected',
          host: '192.168.1.11',
          port: 10002,
          platform: 'linux',
          state: ConnectionLifecycleState.connected,
          discovered: true,
          locallyTrusted: true,
          remotelyTrusted: true,
          lastSeenAt: DateTime(2026, 1, 1),
        ),
        'trusted': DevicePresence(
          peerId: 'trusted',
          name: 'Trusted',
          host: '192.168.1.12',
          port: 10002,
          platform: 'linux',
          state: ConnectionLifecycleState.candidate,
          discovered: true,
          locallyTrusted: true,
          remotelyTrusted: true,
          lastSeenAt: DateTime(2026, 1, 1),
        ),
        'nearby': DevicePresence(
          peerId: 'nearby',
          name: 'Nearby',
          host: '192.168.1.13',
          port: 10002,
          platform: 'linux',
          state: ConnectionLifecycleState.candidate,
          discovered: true,
          locallyTrusted: false,
          remotelyTrusted: false,
          lastSeenAt: DateTime(2026, 1, 1),
        ),
      },
      selectedPeerId: null,
      connectedPeerIds: const {'connected'},
      connectedTitle: 'Connected',
      trustedTitle: 'Trusted',
    );

    expect(state.connectedCount, 1);
    expect(state.trustedCount, 2);
    expect(state.sections.map((section) => section.title), [
      'Connected',
      'Trusted',
      'Nearby',
      'History',
    ]);
    expect(state.selectedDevice?.uid, 'connected');
  });

  test('keeps explicit selection even when another peer is connected', () {
    final state = DeviceWorkspaceStateBuilder.build(
      devices: [
        buildDevice('first', name: 'First'),
        buildDevice('second', name: 'Second'),
      ],
      presences: const {},
      selectedPeerId: 'second',
      connectedPeerIds: const {'first'},
      connectedTitle: 'Connected',
      trustedTitle: 'Trusted',
    );

    expect(state.selectedDevice?.uid, 'second');
  });

  test('keeps explicit selection independent from multiple connected peers',
      () {
    final state = DeviceWorkspaceStateBuilder.build(
      devices: [
        buildDevice('peer-b', name: 'Peer B'),
        buildDevice('peer-c', name: 'Peer C'),
        buildDevice('selected', name: 'Selected'),
      ],
      presences: const {},
      selectedPeerId: 'selected',
      connectedPeerIds: const {'peer-b', 'peer-c'},
      connectedTitle: 'Connected',
      trustedTitle: 'Trusted',
    );

    expect(state.connectedCount, 2);
    expect(state.selectedDevice?.uid, 'selected');
    expect(
      state.sections
          .firstWhere((section) => section.title == 'Connected')
          .items
          .map((item) => item.device.uid),
      unorderedEquals(['peer-b', 'peer-c']),
    );
  });
}
