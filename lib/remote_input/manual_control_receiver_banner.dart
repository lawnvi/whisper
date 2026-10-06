import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/socket/svrmanager.dart';

class ManualControlReceiverBanner extends StatelessWidget {
  const ManualControlReceiverBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final coordinator = RemoteInputCoordinator.shared;
    return ListenableBuilder(
      listenable: coordinator,
      builder: (context, _) {
        final state = coordinator.state;
        if (!coordinator.isManual ||
            state.role != RemoteInputRuntimeRole.sink ||
            state.status == RemoteInputRuntimeStatus.idle) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context)!;
        final sockets = WsSvrManager();
        final name =
            sockets.remoteProfileFor(state.peerId)?.device.name ?? state.peerId;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.mobileControlReceiving(name)),
                TextButton.icon(
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(l10n.mobileControlStop),
                  onPressed: () => coordinator.stopSharing(
                    sendControl: (control) {
                      sockets.sendRemoteInputControlTo(state.peerId, control);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
