import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/helper/windows_input_service.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/widget/app_dialogs.dart';

String _installLabel(AppLocalizations l10n, WindowsInputServiceState state) =>
    state == WindowsInputServiceState.notInstalled
    ? l10n.windowsLockScreenInputInstall
    : l10n.windowsLockScreenInputRepair;

/// Confirms and then runs the action the service's current state allows. A
/// running service is uninstalled; anything else is installed over, unless
/// [remove] says otherwise because the button the user pressed said so.
Future<void> changeWindowsLockScreenInput(
  BuildContext context, {
  WindowsInputServiceController? controller,
  bool? remove,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final service = controller ?? WindowsInputServiceController.shared;
  if (service.busy) return;
  final uninstall = remove ?? service.state == WindowsInputServiceState.running;
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
