import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Key, Theme;
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/pairing_request.dart';

const pairingCodeKey = Key('pairing-code');
const pairingRejectKey = Key('pairing-reject');
const pairingApproveKey = Key('pairing-approve');

Future<void> showPairingDialog(
  BuildContext context, {
  required PairingRequest request,
  required void Function(bool) resolve,
}) async {
  BuildContext? dialogContext;
  var routeOpen = true;
  var cancelled = false;

  void dismiss([bool? decision]) {
    final activeContext = dialogContext;
    if (!routeOpen || activeContext == null || !activeContext.mounted) {
      return;
    }
    routeOpen = false;
    Navigator.of(activeContext).pop(decision);
  }

  final cancellation = request.cancellation;
  if (cancellation != null) {
    unawaited(cancellation.then((_) {
      cancelled = true;
      dismiss();
    }));
  }
  final decision = await showCupertinoDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      dialogContext = context;
      if (cancelled) {
        scheduleMicrotask(dismiss);
      }
      return PairingDialog(
        request: request,
        onResolved: dismiss,
      );
    },
  );
  routeOpen = false;
  resolve(decision ?? false);
}

class PairingDialog extends StatefulWidget {
  const PairingDialog({
    super.key,
    required this.request,
    required this.onResolved,
  });

  final PairingRequest request;
  final ValueChanged<bool> onResolved;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  bool _resolved = false;

  void _resolve(bool allow) {
    if (_resolved) {
      return;
    }
    setState(() => _resolved = true);
    widget.onResolved(allow);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final title = switch (widget.request.reason) {
      PairingReason.newDevice => l10n.pairingNewDeviceTitle,
      PairingReason.identityChanged => l10n.pairingIdentityChangedTitle,
      PairingReason.legacyTrustWithoutPin => l10n.pairingLegacyTrustTitle,
    };
    final description = switch (widget.request.reason) {
      PairingReason.newDevice =>
        l10n.pairingNewDeviceDescription(widget.request.device.name),
      PairingReason.identityChanged =>
        l10n.pairingIdentityChangedDescription(widget.request.device.name),
      PairingReason.legacyTrustWithoutPin =>
        l10n.pairingLegacyTrustDescription(widget.request.device.name),
    };
    final code = '${widget.request.pairingCode.substring(0, 3)} '
        '${widget.request.pairingCode.substring(3)}';

    return CupertinoAlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(description),
            const SizedBox(height: 16),
            Text(
              l10n.pairingCompareCode,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            Semantics(
              key: pairingCodeKey,
              label: l10n.pairingCodeSemantics(widget.request.pairingCode),
              liveRegion: true,
              child: ExcludeSemantics(
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    code,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        CupertinoDialogAction(
          key: pairingRejectKey,
          isDestructiveAction: true,
          onPressed: _resolved ? null : () => _resolve(false),
          child: Text(l10n.pairingReject),
        ),
        if (widget.request.canApprove)
          CupertinoDialogAction(
            key: pairingApproveKey,
            onPressed: _resolved ? null : () => _resolve(true),
            child: Text(l10n.pairingApprove),
          ),
      ],
    );
  }
}
