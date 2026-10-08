import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';

enum RemoteInputPeerPhase { connecting, ready, controlling, receiving }

/// UI state belongs to a live peer/session, never to a selected layout tile.
class RemoteInputPeerActivity {
  const RemoteInputPeerActivity({
    required this.peerId,
    required this.sessionId,
    required this.phase,
    this.isManual = false,
  });

  final String peerId;
  final String sessionId;
  final RemoteInputPeerPhase phase;
  final bool isManual;

  bool get isActive =>
      phase == RemoteInputPeerPhase.controlling ||
      phase == RemoteInputPeerPhase.receiving;

  String label(AppLocalizations l10n) => switch (phase) {
    RemoteInputPeerPhase.connecting => l10n.mobileControlPreparing,
    RemoteInputPeerPhase.ready => l10n.remoteInputPeerReady,
    RemoteInputPeerPhase.controlling => l10n.remoteInputPeerControlling,
    RemoteInputPeerPhase.receiving => l10n.remoteInputPeerReceiving,
  };

  String description(AppLocalizations l10n, String name) => switch (phase) {
    RemoteInputPeerPhase.controlling => l10n.remoteInputWorkspaceStatusActive(
      name,
    ),
    RemoteInputPeerPhase.receiving => l10n.mobileControlReceiving(name),
    _ => '$name · ${label(l10n)}',
  };

  static RemoteInputPeerActivity? forPeer({
    required String peerId,
    required bool isConnected,
    required RemoteInputRuntimeState legacy,
    required bool isManual,
    required RemoteInputWorkspaceSnapshot workspace,
  }) {
    if (!isConnected || peerId.isEmpty) return null;
    if (legacy.peerId == peerId &&
        legacy.sessionId.isNotEmpty &&
        legacy.role != RemoteInputRuntimeRole.none &&
        (legacy.isActive ||
            legacy.isBusy ||
            legacy.status == RemoteInputRuntimeStatus.armed)) {
      return RemoteInputPeerActivity(
        peerId: peerId,
        sessionId: legacy.sessionId,
        isManual: isManual,
        phase: legacy.isBusy
            ? RemoteInputPeerPhase.connecting
            : !legacy.isActive
            ? RemoteInputPeerPhase.ready
            : legacy.role == RemoteInputRuntimeRole.source
            ? RemoteInputPeerPhase.controlling
            : RemoteInputPeerPhase.receiving,
      );
    }
    final target = workspace.targets[peerId];
    if (!workspace.isControllerLive ||
        target == null ||
        !target.isLive ||
        target.sessionId.isEmpty) {
      return null;
    }
    return RemoteInputPeerActivity(
      peerId: peerId,
      sessionId: target.sessionId,
      phase: !target.isConnected
          ? RemoteInputPeerPhase.connecting
          : workspace.activePeerId == peerId
          ? RemoteInputPeerPhase.controlling
          : RemoteInputPeerPhase.ready,
    );
  }
}
