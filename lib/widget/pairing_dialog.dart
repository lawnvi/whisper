import 'package:flutter/material.dart';
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
  final decision = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PairingDialog(
      request: request,
      onResolved: (allow) => Navigator.of(context).pop(allow),
    ),
  );
  resolve(decision ?? false);
}

class PairingDialog extends StatelessWidget {
  const PairingDialog({
    super.key,
    required this.request,
    required this.onResolved,
  });

  final PairingRequest request;
  final ValueChanged<bool> onResolved;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final title = switch (request.reason) {
      PairingReason.newDevice => l10n.pairingNewDeviceTitle,
      PairingReason.identityChanged => l10n.pairingIdentityChangedTitle,
      PairingReason.legacyTrustWithoutPin => l10n.pairingLegacyTrustTitle,
    };
    final description = switch (request.reason) {
      PairingReason.newDevice =>
        l10n.pairingNewDeviceDescription(request.device.name),
      PairingReason.identityChanged =>
        l10n.pairingIdentityChangedDescription(request.device.name),
      PairingReason.legacyTrustWithoutPin =>
        l10n.pairingLegacyTrustDescription(request.device.name),
    };
    final code = '${request.pairingCode.substring(0, 3)} '
        '${request.pairingCode.substring(3)}';

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
              label: l10n.pairingCodeSemantics(request.pairingCode),
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
        TextButton(
          key: pairingRejectKey,
          onPressed: () => onResolved(false),
          child: Text(l10n.pairingReject),
        ),
        if (request.canApprove)
          FilledButton(
            key: pairingApproveKey,
            onPressed: () => onResolved(true),
            child: Text(l10n.pairingApprove),
          ),
      ],
    );
  }
}
