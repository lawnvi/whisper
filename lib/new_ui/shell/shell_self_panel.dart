import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/state/pairing_invite.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// docs/design/surfaces.md「这台面板」, the prototype's `selfSheet`.
class ShellSelfPanel extends StatefulWidget {
  const ShellSelfPanel({
    super.key,
    required this.self,
    required this.onEnterAddress,
  });

  final DeviceData? self;
  final VoidCallback onEnterAddress;

  @override
  State<ShellSelfPanel> createState() => _ShellSelfPanelState();
}

class _ShellSelfPanelState extends State<ShellSelfPanel> {
  PairingInvite? _invite;
  String? _fingerprint;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final local = widget.self ?? await LocalSetting().instance();
    final host = await getLocalIpAddress();
    final identity = await DeviceIdentityStore().loadOrCreate();
    final hash = identityPublicKeyHash(identity.publicKeyBase64Url);
    PairingInvite? invite;
    try {
      invite = PairingInvite(
        host: host,
        port: local.port,
        peerId: local.uid,
        publicKeyHash: hash,
      );
    } on PairingInviteFormatException {
      // No usable address on this network.
    }
    if (mounted) {
      setState(() {
        _invite = invite;
        _fingerprint = hash;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    const type = WhisperType(touch: false);
    final self = widget.self;
    final invite = _invite;
    final fingerprint = _fingerprint;
    Widget code(String value) => Flexible(
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: c.ink2),
      ),
    );
    return ShellSheetBody(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (self != null)
            Center(
              child: DeviceArt(
                kind: deviceKindFor(self.platform, name: self.name),
                os: deviceOsFor(self.platform),
                wallpaper: DeviceWallpaper.self,
                size: 96,
              ),
            ),
          const SizedBox(height: 10),
          Text(
            self?.name ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: type.title,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 14),
          if (_loaded && invite == null)
            Text(
              l10n.shellSelfNoLan,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: type.note, height: 1.5, color: c.warn),
            )
          else if (invite != null) ...[
            Center(
              child: Container(
                width: 148,
                height: 148,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(WhisperRadius.m),
                  boxShadow: WhisperShadow.e1(Theme.of(context).brightness),
                ),
                child: QrImageView(
                  data: invite.encode(),
                  padding: const EdgeInsets.all(10),
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          ShellGroup(
            flat: true,
            children: [
              ShellRow(
                label: l10n.shellSelfAddress,
                trailing: code(
                  invite == null ? '—' : '${invite.host}:${invite.port}',
                ),
              ),
              ShellRow(
                label: l10n.shellSelfFingerprint,
                trailing: code(fingerprint ?? '—'),
              ),
            ],
          ),
        ],
      ),
      actions: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ShellButton(
            label: l10n.shellEnterAddress,
            onTap: () {
              Navigator.of(context).pop();
              widget.onEnterAddress();
            },
          ),
          const SizedBox(width: 8),
          ShellButton(
            label: l10n.shellDone,
            kind: ShellButtonKind.primary,
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
