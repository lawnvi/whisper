import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Key, Theme;
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/pairing_request.dart';

const pairingCodeKey = Key('pairing-code');
const pairingCancelKey = Key('pairing-cancel');
const pairingRejectKey = Key('pairing-reject');
const pairingApproveKey = Key('pairing-approve');

final class _PairingLifecycleObserver with WidgetsBindingObserver {
  _PairingLifecycleObserver(this.onResumed);

  final void Function() onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onResumed();
    }
  }
}

Future<void> showPairingDialog(
  BuildContext context, {
  required PairingRequest request,
  required void Function(bool) resolve,
}) async {
  BuildContext? dialogContext;
  Route<bool?>? dialogRoute;
  StreamSubscription<void>? cancellationSubscription;
  void Function()? removeDismissListener;
  Completer<void>? lifecycleWake;
  var routeOpen = true;
  var cancelled = false;

  void dismiss([bool? decision]) {
    final activeContext = dialogContext;
    if (!routeOpen || activeContext == null || !activeContext.mounted) {
      return;
    }
    routeOpen = false;
    final route = dialogRoute;
    if (route != null && route.isActive) {
      Navigator.of(activeContext).removeRoute(route, decision);
    }
  }

  void cancelPresentation() {
    cancelled = true;
    dismiss();
    final wake = lifecycleWake;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
  }

  final presentation = request.presentation;
  if (presentation != null) {
    removeDismissListener = presentation.addDismissListener(
      cancelPresentation,
    );
  } else if (request.cancellation case final cancellation?) {
    cancellationSubscription = cancellation.asStream().listen((_) {
      cancelPresentation();
    });
  }
  if (cancelled) {
    removeDismissListener?.call();
    unawaited(cancellationSubscription?.cancel());
    return;
  }
  final binding = WidgetsBinding.instance;
  if (binding.lifecycleState case final state?
      when state != AppLifecycleState.resumed) {
    final wake = lifecycleWake = Completer<void>();
    final observer = _PairingLifecycleObserver(() {
      if (!wake.isCompleted) {
        wake.complete();
      }
    });
    binding.addObserver(observer);
    if (binding.lifecycleState == AppLifecycleState.resumed &&
        !wake.isCompleted) {
      wake.complete();
    }
    await wake.future;
    binding.removeObserver(observer);
    lifecycleWake = null;
    if (cancelled) {
      removeDismissListener?.call();
      unawaited(cancellationSubscription?.cancel());
      return;
    }
  }
  bool? decision;
  try {
    decision = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        dialogContext = context;
        dialogRoute = ModalRoute.of(context);
        if (cancelled) {
          scheduleMicrotask(dismiss);
        }
        return PairingDialog(
          request: request,
          onResolved: dismiss,
        );
      },
    );
  } finally {
    routeOpen = false;
    removeDismissListener?.call();
    unawaited(cancellationSubscription?.cancel());
    dialogContext = null;
    dialogRoute = null;
  }
  if (!cancelled) {
    resolve(decision ?? false);
  }
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
        if (widget.request.isInitiator)
          CupertinoDialogAction(
            key: pairingCancelKey,
            onPressed: _resolved ? null : () => _resolve(false),
            child: Text(l10n.cancel),
          )
        else ...<Widget>[
          CupertinoDialogAction(
            key: pairingRejectKey,
            isDestructiveAction: true,
            onPressed: _resolved ? null : () => _resolve(false),
            child: Text(l10n.pairingReject),
          ),
          CupertinoDialogAction(
            key: pairingApproveKey,
            onPressed: _resolved ? null : () => _resolve(true),
            child: Text(l10n.pairingApprove),
          ),
        ],
      ],
    );
  }
}
