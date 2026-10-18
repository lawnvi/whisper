import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart';
import 'package:whisper/window_stream/linux/gnome_shell_helper.dart';

/// The helper's settings row, in the settings page's own style: icon, title,
/// a one-line explanation, and the state as iOS settings show a value (a
/// coloured dot, a quiet label and the disclosure arrow). Tapping it offers
/// the one action the state allows. Place it inside a SettingsSectionSurface.
class GnomeHelperTile extends StatefulWidget {
  const GnomeHelperTile({super.key, this.controller});

  final GnomeShellHelperController? controller;

  @override
  State<GnomeHelperTile> createState() => _GnomeHelperTileState();
}

class _GnomeHelperTileState extends State<GnomeHelperTile>
    with WidgetsBindingObserver {
  GnomeShellHelperController get _controller =>
      widget.controller ?? GnomeShellHelperController.shared;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_controller.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from GNOME's Extensions app, say.
    if (state == AppLifecycleState.resumed) unawaited(_controller.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!controller.supported) return const SizedBox.shrink();
    final palette = context.whisperPalette;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final title = l10n.gnomeHelperTitle;
        final hint = controller.busy
            ? l10n.gnomeHelperWorking
            : l10n.gnomeHelperHint;
        final enabled = !controller.busy;
        void open() =>
            unawaited(changeGnomeShellHelper(context, controller: controller));
        return Semantics(
          container: true,
          excludeSemantics: true,
          button: true,
          enabled: enabled,
          label: '$title, ${_stateLabel(context, controller.state)}, $hint',
          onTap: enabled ? open : null,
          child: FocusableActionDetector(
            enabled: enabled,
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  open();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: enabled ? open : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(
                              Icons.picture_in_picture_alt_outlined,
                              color: isDark
                                  ? Colors.grey[400]
                                  : CupertinoColors.systemGrey,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontSize: 16,
                                    height: 1.5,
                                    letterSpacing: 0,
                                    color: theme.colorScheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  hint,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 13,
                                    height: 1.5,
                                    letterSpacing: 0,
                                    color: palette.textMuted,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    GnomeHelperStatus(controller: controller),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

String _stateLabel(BuildContext context, GnomeShellHelperState state) {
  final l10n = AppLocalizations.of(context)!;
  return switch (state) {
    GnomeShellHelperState.ready => l10n.gnomeHelperReady,
    GnomeShellHelperState.needsRelogin => l10n.gnomeHelperNeedsRelogin,
    GnomeShellHelperState.outdated => l10n.gnomeHelperOutdated,
    GnomeShellHelperState.disabled => l10n.gnomeHelperDisabled,
    GnomeShellHelperState.extensionsOff => l10n.gnomeHelperExtensionsOff,
    _ => l10n.gnomeHelperNotInstalled,
  };
}

/// The state before the disclosure arrow: a coloured dot (or a spinner while
/// working) and a quiet label, so the state does not rest on colour alone.
class GnomeHelperStatus extends StatelessWidget {
  const GnomeHelperStatus({super.key, required this.controller});

  final GnomeShellHelperController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    final state = controller.state;
    final color = switch (state) {
      GnomeShellHelperState.ready => palette.trusted,
      GnomeShellHelperState.needsRelogin ||
      GnomeShellHelperState.outdated ||
      GnomeShellHelperState.disabled ||
      GnomeShellHelperState.extensionsOff => palette.warning,
      _ => palette.textMuted.withValues(alpha: 0.5),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controller.busy || !controller.checked)
          const CupertinoActivityIndicator(radius: 7)
        else
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        const SizedBox(width: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: Text(
            controller.checked ? _stateLabel(context, state) : '',
            key: ValueKey<GnomeShellHelperState>(state),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 14,
              letterSpacing: 0,
              color: palette.textMuted,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Icon(Icons.arrow_forward_ios, size: 14, color: palette.textMuted),
      ],
    );
  }
}

/// Explains the state and runs the action it allows: install or update,
/// log out to finish, turn it (or GNOME extensions) back on.
Future<void> changeGnomeShellHelper(
  BuildContext context, {
  GnomeShellHelperController? controller,
}) async {
  final helper = controller ?? GnomeShellHelperController.shared;
  if (helper.busy) return;
  await helper.refresh();
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  switch (helper.state) {
    case GnomeShellHelperState.unsupported:
      return;
    case GnomeShellHelperState.ready:
      await confirmAction(
        context,
        title: l10n.gnomeHelperTitle,
        description: l10n.gnomeHelperReadyDesc,
        confirmButtonText: l10n.gnomeHelperDone,
        cancelButtonText: l10n.gnomeHelperLater,
      );
      return;
    case GnomeShellHelperState.notInstalled:
    case GnomeShellHelperState.outdated:
      final update = helper.state == GnomeShellHelperState.outdated;
      final confirmed = await confirmAction(
        context,
        title: l10n.gnomeHelperTitle,
        description: (update
            ? l10n.gnomeHelperUpdateDesc
            : l10n.gnomeHelperInstallDesc),
        confirmButtonText: (update
            ? l10n.gnomeHelperUpdate
            : l10n.gnomeHelperInstall),
        cancelButtonText: l10n.gnomeHelperLater,
      );
      if (!confirmed) return;
      final result = await helper.install();
      if (!context.mounted) return;
      if (result == GnomeShellHelperResult.failed) {
        showAppToast(l10n.gnomeHelperFailed, tone: AppToastTone.error);
      } else if (helper.state == GnomeShellHelperState.needsRelogin) {
        showAppToast(l10n.gnomeHelperInstalled, tone: AppToastTone.success);
      }
      return;
    case GnomeShellHelperState.needsRelogin:
      final logOut = await confirmAction(
        context,
        title: l10n.gnomeHelperTitle,
        description: l10n.gnomeHelperReloginDesc,
        confirmButtonText: l10n.gnomeHelperLogOut,
        cancelButtonText: l10n.gnomeHelperLater,
      );
      if (logOut) await helper.logOut();
      return;
    case GnomeShellHelperState.disabled:
    case GnomeShellHelperState.extensionsOff:
      final all = helper.state == GnomeShellHelperState.extensionsOff;
      final confirmed = await confirmAction(
        context,
        title: l10n.gnomeHelperTitle,
        description: (all
            ? l10n.gnomeHelperExtensionsOffDesc
            : l10n.gnomeHelperDisabledDesc),
        confirmButtonText: (all
            ? l10n.gnomeHelperTurnOnExtensions
            : l10n.gnomeHelperTurnOn),
        cancelButtonText: l10n.gnomeHelperLater,
      );
      if (!confirmed) return;
      final result = await helper.enable();
      if (!context.mounted) return;
      if (result == GnomeShellHelperResult.failed) {
        showAppToast(l10n.gnomeHelperFailed, tone: AppToastTone.error);
      }
      return;
  }
}
