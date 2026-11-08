import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whisper/new_ui/shell/shell_manual_connect.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_touch.dart';
import 'package:whisper/helper/helper.dart' show isMobile;
import 'package:whisper/new_ui/phone/phone_connect_page.dart';
import 'package:whisper/theme/whisper_ui.dart' show WhisperPageRoute;
import 'package:whisper/state/pairing_invite.dart';
import 'package:whisper/state/peer_endpoint.dart';

final class PairingQrResult {
  PairingQrResult.qr(PairingInvite value)
    : invite = value,
      endpoint = PeerEndpoint(host: value.host, port: value.port);

  const PairingQrResult.manual(this.endpoint) : invite = null;

  final PairingInvite? invite;
  final PeerEndpoint endpoint;
}

Future<PairingQrResult?> showPairingQrDialog(
  BuildContext context, {
  required PairingInvite? localInvite,
  String? localPeerId,
  bool startWithAddress = false,
  bool startWithScanner = true,
  PairingQrDialogController? controller,
  String localName = '',
  String? localFingerprint,
  Future<PairingInvite?> Function()? reloadInvite,
  bool deeper = false,
}) {
  // surfaces.md「手机 · 连接设备」: a page of the stack, starting on this
  // phone's code, whatever the caller last preferred.
  if ((isMobile() || ShellContent.attached)) {
    Widget page(BuildContext context) => PhoneConnectPage(
      localInvite: localInvite,
      localName: localName,
      localPeerId: localPeerId,
      fingerprint: localFingerprint,
      startWithAddress: startWithAddress,
      controller: controller,
      reloadInvite: reloadInvite,
    );
    // In the content area, like settings. From a row of settings it is a page
    // further in, with a way back to them.
    if (ShellContent.attached) {
      return deeper
          ? ShellContent.push<PairingQrResult>(
              WhisperPageRoute<PairingQrResult>(builder: page),
            )
          : ShellContent.pushTop<PairingQrResult>(page);
    }
    return Navigator.of(
      context,
      rootNavigator: true,
    ).push<PairingQrResult>(WhisperPageRoute<PairingQrResult>(builder: page));
  }
  // The desktop's code is in 这台面板: what is left to ask for is an address.
  return showShellSheet<PairingQrResult>(
    context,
    builder: (context) => ShellManualConnect(localHost: localInvite?.host),
  );
}

final class PairingQrDialogController {
  VoidCallback? _dismiss;

  void dismiss() => _dismiss?.call();

  /// For whatever is showing the code: the dialog, or the phone's page.
  void attach(VoidCallback dismiss) => _dismiss = dismiss;

  void detach(VoidCallback dismiss) {
    if (identical(_dismiss, dismiss)) {
      _dismiss = null;
    }
  }
}
