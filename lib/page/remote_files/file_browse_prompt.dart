import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../helper/helper.dart';
import '../../helper/notification.dart';
import '../../helper/notification_l10n.dart';
import '../../l10n/app_localizations.dart';
import '../../remote_files/fs_host.dart';
import '../../remote_files/mount/remote_mounts.dart';
import '../window_stream/flow_space_theme.dart';
import 'files_icons.dart';

/// Asks "‹device› wants to browse your files" over the whole app whenever
/// [FileBrowseHost] has a request. Allow once, always allow (remembered for
/// that device) or don't allow; silence for a minute is a no.
class FileBrowsePromptHost extends StatefulWidget {
  const FileBrowsePromptHost({
    super.key,
    required this.child,
    FileBrowseGate? gate,
  }) : _gate = gate;

  final Widget child;
  final FileBrowseGate? _gate;

  @override
  State<FileBrowsePromptHost> createState() => _FileBrowsePromptHostState();
}

class _FileBrowsePromptHostState extends State<FileBrowsePromptHost> {
  FileBrowseGate get _gate => widget._gate ?? FileBrowseHost.shared.gate;
  FileBrowseRequest? _announced;

  @override
  void initState() {
    super.initState();
    _gate.addListener(_onGate);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A device mounted in the file manager names its roots in the app's
    // own language, also when mounted on connect with no window open.
    final l10n = AppLocalizations.of(context);
    if (l10n != null) {
      RemoteMounts.shared.rootNamer = (root) => fsRootLabel(l10n, root);
    }
  }

  @override
  void dispose() {
    _gate.removeListener(_onGate);
    super.dispose();
  }

  void _onGate() {
    final pending = _gate.pending;
    if (pending != null && !identical(pending, _announced)) {
      _announced = pending;
      HapticFeedback.mediumImpact();
      _announce(pending);
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// The question must be seen: raise the window on desktops, notify when
  /// the phone app is in the background.
  void _announce(FileBrowseRequest request) {
    if (isDesktop()) {
      windowManager.show();
      windowManager.focus();
      return;
    }
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      final l10n = resolveNotificationL10n();
      NotificationHelper().showNotification(
        title: l10n.remoteFilesPromptTitle(request.deviceName),
        body: l10n.remoteFilesPromptBodyPhone,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _gate.pending;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            ignoring: request == null,
            child: AnimatedOpacity(
              duration: FlowSpaceTokens.quickDuration,
              opacity: request == null ? 0 : 1,
              child: Material(
                type: MaterialType.transparency,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.32),
                  child: request == null
                      ? const SizedBox.expand()
                      : Center(
                          child: _PromptCard(
                            request: request,
                            onDecide: _gate.decide,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({required this.request, required this.onDecide});

  final FileBrowseRequest request;
  final ValueChanged<FileBrowseDecision> onDecide;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FlowSpaceColors.of(context);
    final phone = Platform.isAndroid || Platform.isIOS;
    Widget button(
      String label,
      FileBrowseDecision decision, {
      bool primary = false,
    }) {
      return SizedBox(
        width: double.infinity,
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: 13),
          color: primary ? colors.scheme.primary : colors.raisedSecondary,
          borderRadius: BorderRadius.circular(14),
          onPressed: () => onDecide(decision),
          child: Text(
            label,
            style: TextStyle(
              color: primary ? Colors.white : colors.label,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) => onDecide(FileBrowseDecision.deny),
          ),
        },
        child: Focus(
          autofocus: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: FlowGlass(
                radius: 28,
                tint: colors.raised.withValues(alpha: 0.92),
                padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: ShapeDecoration(
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        color: colors.scheme.primary.withValues(alpha: 0.12),
                      ),
                      child: Icon(
                        CupertinoIcons.folder_fill,
                        color: colors.scheme.primary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.remoteFilesPromptTitle(request.deviceName),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.label,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      phone
                          ? l10n.remoteFilesPromptBodyPhone
                          : l10n.remoteFilesPromptBodyDesktop,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.secondaryLabel,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    button(
                      l10n.remoteFilesAllowOnce,
                      FileBrowseDecision.once,
                      primary: true,
                    ),
                    const SizedBox(height: 8),
                    button(
                      l10n.remoteFilesAllowAlways,
                      FileBrowseDecision.always,
                    ),
                    const SizedBox(height: 8),
                    button(l10n.remoteFilesDeny, FileBrowseDecision.deny),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
