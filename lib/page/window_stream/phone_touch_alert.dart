import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../helper/toast.dart';
import '../../l10n/app_localizations.dart';
import '../../window_stream/android/agent/android_agent_source.dart';
import '../../window_stream/window_stream_coordinator.dart';
import 'flow_space_theme.dart';

/// Tells the desktop user when a phone's own screen stopped taking touches
/// because of a page streaming left behind, and offers to close that page.
class PhoneTouchAlertHost extends StatefulWidget {
  const PhoneTouchAlertHost({super.key, required this.child});

  final Widget child;

  @override
  State<PhoneTouchAlertHost> createState() => _PhoneTouchAlertHostState();
}

class _PhoneTouchAlertHostState extends State<PhoneTouchAlertHost> {
  StreamSubscription<PhoneTouchAlert>? _alerts;
  PhoneTouchAlert? _alert;
  BlockedApp? _app;
  String _label = '';
  bool _fixing = false;

  @override
  void initState() {
    super.initState();
    _alerts = WindowStreamCoordinator.shared.touchAlerts.listen(_onAlert);
  }

  @override
  void dispose() {
    _alerts?.cancel();
    super.dispose();
  }

  Future<void> _onAlert(PhoneTouchAlert alert) async {
    if (_alert != null) {
      return;
    }
    final app = alert.apps.first;
    var label = app.appId;
    try {
      for (final entry in await alert.source.apps()) {
        if (entry.id == app.appId) {
          label = entry.label;
          break;
        }
      }
    } catch (_) {
      // The package name will do.
    }
    if (!mounted) {
      return;
    }
    unawaited(windowManager.show());
    unawaited(windowManager.focus());
    setState(() {
      _alert = alert;
      _app = app;
      _label = label;
    });
  }

  Future<void> _fix() async {
    final alert = _alert;
    final app = _app;
    if (alert == null || app == null || _fixing) {
      return;
    }
    setState(() => _fixing = true);
    final l10n = AppLocalizations.of(context)!;
    final ok = await alert.source
        .repairTouch(app.taskId)
        .catchError((_) => false);
    if (!mounted) {
      return;
    }
    setState(() {
      _alert = null;
      _fixing = false;
    });
    showAppToast(
      ok ? l10n.windowStreamTouchBlockedFixed : l10n.remoteFilesFailed,
      tone: ok ? AppToastTone.success : AppToastTone.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final alert = _alert;
    return Stack(
      children: [
        widget.child,
        if (alert != null)
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.32),
                child: Center(child: _card(context, alert)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _card(BuildContext context, PhoneTouchAlert alert) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FlowSpaceColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: FlowGlass(
          radius: 28,
          tint: colors.raised.withValues(alpha: 0.94),
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.hand_raised_slash_fill,
                size: 34,
                color: CupertinoColors.systemOrange,
              ),
              const SizedBox(height: 14),
              Text(
                l10n.windowStreamTouchBlockedTitle(alert.source.info.name),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.label,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.windowStreamTouchBlockedBody(_label),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.secondaryLabel,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  color: colors.scheme.primary,
                  borderRadius: BorderRadius.circular(14),
                  onPressed: _fixing ? null : () => unawaited(_fix()),
                  child: _fixing
                      ? const CupertinoActivityIndicator(color: Colors.white)
                      : Text(
                          l10n.windowStreamTouchBlockedFix,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  color: colors.raisedSecondary,
                  borderRadius: BorderRadius.circular(14),
                  onPressed: () => setState(() => _alert = null),
                  child: Text(
                    l10n.windowStreamTouchBlockedLater,
                    style: TextStyle(
                      color: colors.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
