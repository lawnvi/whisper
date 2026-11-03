import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/mobile_control_screen.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/svrmanager.dart';

/// The page that controls [device] from this phone or tablet.
MobileControlScreen mobileControlPage({
  required DeviceData device,
  required DeviceData? self,
  required AppLocalizations l10n,
  Widget? deviceArt,
}) {
  final socketManager = WsSvrManager();
  final coordinator = RemoteInputCoordinator.shared;

  void send(RemoteInputControlMessage control) {
    Future<void> stopIfCurrent() async {
      if (coordinator.state.sessionId == control.sessionId) {
        await coordinator.stopLocal();
      }
    }

    unawaited(
      socketManager
          .sendRemoteInputControlTo(control.sinkPeerId, control)
          .then<void>((sent) async {
            if (!sent) await stopIfCurrent();
          })
          .catchError((Object _) => stopIfCurrent()),
    );
  }

  return MobileControlScreen(
    peerId: device.uid,
    peerName: device.name,
    deviceArt: deviceArt,
    targets: () => [
      for (final peerId in socketManager.connectedPeerIds)
        if (socketManager.supportsManualInputFor(peerId))
          MobileControlTarget(
            peerId,
            socketManager.remoteProfileFor(peerId)!.device.name,
            platform: socketManager.remoteProfileFor(peerId)!.device.platform,
          ),
    ],
    onStart: (peerId) async {
      final local = self ?? await LocalSetting().instance();
      final stored = await LocalDatabase().fetchDevice(peerId);
      final target = socketManager.remoteProfileFor(peerId)?.device;
      if (!socketManager.isConnectedTo(peerId) || target == null) {
        throw MobileControlStartException(l10n.connectFailed);
      }
      if (stored?.auth != true ||
          !socketManager.remotePeerTrustsPeer(peerId, local.uid)) {
        throw MobileControlStartException(l10n.remoteInputRequiresMutualTrust);
      }
      if (!socketManager.supportsManualInputFor(peerId)) {
        throw MobileControlStartException(l10n.remoteInputPeerUnsupported);
      }
      await coordinator.startSharingToConnectedPeer(
        sourcePeerId: local.uid,
        sinkPeerId: peerId,
        sinkHost: target.host,
        sinkPort: target.port,
        mode: RemoteInputMode.manual,
        releaseHotkey: '',
        isMutuallyTrusted: true,
        remoteCanInject: true,
        sendControl: send,
      );
    },
    onStop: () => coordinator.stopSharing(sendControl: send),
  );
}
