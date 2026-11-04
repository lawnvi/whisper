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
}
