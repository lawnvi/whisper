import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_peer_activity.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';

void main() {
  RemoteInputPeerActivity? activity(
    String peer, {
    bool connected = true,
    bool manual = false,
    RemoteInputRuntimeState legacy = const RemoteInputRuntimeState.idle(),
    RemoteInputWorkspaceSnapshot workspace =
        const RemoteInputWorkspaceSnapshot.idle(),
  }) => RemoteInputPeerActivity.forPeer(
    peerId: peer,
    isConnected: connected,
    legacy: legacy,
    isManual: manual,
    workspace: workspace,
  );

  const phone = RemoteInputRuntimeState(
    status: RemoteInputRuntimeStatus.active,
    role: RemoteInputRuntimeRole.sink,
    sessionId: 'manual-1',
    peerId: 'phone',
  );

  test(
    'phone control belongs only to the phone, never an unrelated desktop',
    () {
      final current = activity('phone', legacy: phone, manual: true)!;
      expect(current.phase, RemoteInputPeerPhase.receiving);
      expect(current.isManual, isTrue);
      expect(activity('desktop', legacy: phone, manual: true), isNull);
      expect(
        activity('phone', connected: false, legacy: phone, manual: true),
        isNull,
      );
    },
  );

  test('desktop receiver is ready until the controller enters', () {
    RemoteInputPeerActivity? receiver(RemoteInputRuntimeStatus status) =>
        activity(
          'desktop',
          legacy: RemoteInputRuntimeState(
            status: status,
            role: RemoteInputRuntimeRole.sink,
            sessionId: 'edge-1',
            peerId: 'desktop',
          ),
        );

    expect(
      receiver(RemoteInputRuntimeStatus.armed)?.phase,
      RemoteInputPeerPhase.ready,
    );
    expect(
      receiver(RemoteInputRuntimeStatus.active)?.phase,
      RemoteInputPeerPhase.receiving,
    );
    expect(receiver(RemoteInputRuntimeStatus.idle), isNull);
  });

  RemoteInputWorkspaceSnapshot workspace({String active = 'b'}) =>
      RemoteInputWorkspaceSnapshot(
        role: RemoteInputWorkspaceRole.controller,
        status: active.isEmpty
            ? RemoteInputWorkspaceStatus.armed
            : RemoteInputWorkspaceStatus.active,
        sourcePeerId: 'a',
        workspaceSessionId: 'workspace-1',
        activePeerId: active,
        targets: {
          for (final peer in ['b', 'c'])
            peer: RemoteInputWorkspaceTargetSnapshot(
              peerId: peer,
              peerName: peer,
              sessionId: 'session-$peer',
              status: RemoteInputWorkspaceTargetStatus.connected,
            ),
          'd': const RemoteInputWorkspaceTargetSnapshot(
            peerId: 'd',
            peerName: 'd',
            sessionId: 'session-d',
            status: RemoteInputWorkspaceTargetStatus.offering,
          ),
        },
      );

  test(
    'workspace follows the actual active target and clears it on return',
    () {
      expect(
        activity('b', workspace: workspace())?.phase,
        RemoteInputPeerPhase.controlling,
      );
      expect(
        activity('c', workspace: workspace())?.phase,
        RemoteInputPeerPhase.ready,
      );
      expect(
        activity('d', workspace: workspace())?.phase,
        RemoteInputPeerPhase.connecting,
      );
      expect(activity('other', workspace: workspace()), isNull);
      expect(
        activity('b', workspace: workspace(active: 'c'))?.phase,
        RemoteInputPeerPhase.ready,
      );
      expect(
        activity('c', workspace: workspace(active: 'c'))?.phase,
        RemoteInputPeerPhase.controlling,
      );
      expect(
        activity('b', workspace: workspace(active: ''))?.phase,
        RemoteInputPeerPhase.ready,
      );
      expect(activity('b', connected: false, workspace: workspace()), isNull);
    },
  );

  test('terminal workspace state never leaves a control badge', () {
    for (final status in [
      RemoteInputWorkspaceStatus.idle,
      RemoteInputWorkspaceStatus.failed,
    ]) {
      expect(
        activity('b', workspace: workspace().copyWith(status: status)),
        isNull,
      );
    }
  });
}
