import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/helper/windows_input_service.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_dialogs.dart';

/// The lock screen input service's state, shown the way iOS settings show a
/// value: a quiet label before the disclosure arrow, with a coloured dot so
/// the state does not rest on wording alone.
class WindowsLockScreenInputStatus extends StatelessWidget {
  const WindowsLockScreenInputStatus({super.key, required this.controller});

  final WindowsInputServiceController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final palette = context.whisperPalette;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final (label, color) = switch (controller.state) {
          WindowsInputServiceState.running => (
            l10n.windowsLockScreenInputRunning,
            palette.trusted,
          ),
          WindowsInputServiceState.stopped => (
            l10n.windowsLockScreenInputStopped,
            palette.warning,
          ),
          WindowsInputServiceState.outdated => (
            l10n.windowsLockScreenInputOutdated,
            palette.warning,
          ),
          _ => (
            l10n.windowsLockScreenInputNotInstalled,
            palette.textMuted.withValues(alpha: 0.5),
          ),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.busy)
              const CupertinoActivityIndicator(radius: 7)
            else
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: 14,
                letterSpacing: 0,
                color: palette.textMuted,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.arrow_forward_ios, size: 14, color: palette.textMuted),
          ],
        );
      },
    );
  }
}

String _installLabel(AppLocalizations l10n, WindowsInputServiceState state) =>
    state == WindowsInputServiceState.notInstalled
    ? l10n.windowsLockScreenInputInstall
    : l10n.windowsLockScreenInputRepair;

/// Confirms and then runs the action the service's current state allows. A
/// running service is uninstalled; anything else is installed over.
Future<void> changeWindowsLockScreenInput(
  BuildContext context, {
  WindowsInputServiceController? controller,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final service = controller ?? WindowsInputServiceController.shared;
  if (service.busy) return;
  final uninstall = service.state == WindowsInputServiceState.running;
  final confirmed = await confirmAction(
    context,
    title: l10n.windowsLockScreenInput,
    description: uninstall
        ? l10n.windowsLockScreenInputUninstallDesc
        : l10n.windowsLockScreenInputDesc,
    confirmButtonText: uninstall
        ? l10n.windowsLockScreenInputUninstall
        : _installLabel(l10n, service.state),
    cancelButtonText: l10n.cancel,
    isDestructive: uninstall,
  );
  if (!confirmed) return;
  final result = await (uninstall ? service.uninstall() : service.install());
  if (result == WindowsInputServiceResult.failed) {
    showAppToast(l10n.windowsLockScreenInputFailed, tone: AppToastTone.error);
  }
}

/// Whether a running service also reaches UAC prompts, which appear once the
/// session is unlocked. It sits at the end of the service's row, apart from
/// the row's own install and uninstall action.
class WindowsElevatedInputSwitch extends StatelessWidget {
  const WindowsElevatedInputSwitch({super.key, required this.controller});

  final WindowsInputServiceController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final available =
            controller.state == WindowsInputServiceState.running &&
            !controller.busy;
        return Tooltip(
          message: l10n.windowsElevatedInput,
          child: CupertinoSwitch(
            value: controller.elevatedAllowed,
            onChanged: available
                ? (value) => unawaited(
                    changeWindowsElevatedInput(
                      context,
                      value,
                      controller: controller,
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }
}

/// Confirms, spelling out the risk of turning it on, and then changes whether
/// the service reaches UAC prompts. Either way ends in a UAC prompt.
Future<void> changeWindowsElevatedInput(
  BuildContext context,
  bool enable, {
  WindowsInputServiceController? controller,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final service = controller ?? WindowsInputServiceController.shared;
  if (service.busy) return;
  final confirmed = await confirmAction(
    context,
    title: l10n.windowsElevatedInput,
    description: enable
        ? l10n.windowsElevatedInputEnableDesc
        : l10n.windowsElevatedInputDisableDesc,
    confirmButtonText: enable
        ? l10n.windowsElevatedInputEnable
        : l10n.windowsElevatedInputDisable,
    cancelButtonText: l10n.cancel,
    isDestructive: enable,
  );
  if (!confirmed) return;
  final result = await service.setElevatedAllowed(enable);
  if (result == WindowsInputServiceResult.failed) {
    showAppToast(l10n.windowsElevatedInputFailed, tone: AppToastTone.error);
  }
}
