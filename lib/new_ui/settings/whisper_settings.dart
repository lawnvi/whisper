import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whisper/new_ui/shell/shell_touch.dart';
import 'package:whisper/page/settings.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// One at a time, however it is asked for: ⌘, while the tray opens it too.
Route<void>? _open;

/// Opens the settings the way this window has them: in the content area on a
/// touch screen (DESIGN.md「平板和折叠屏」), otherwise the panel, or the phone's
/// page below 600 (docs/design/surfaces.md「设置」). Completes when they close. Callers refresh then, which is what restarts the service after a port
/// change, as it always has.
///
/// [openPairing] and [openShareLinks] are the two rows at the top of the
/// phone's page.
Future<void> showWhisperSettings(
  BuildContext context, {
  required Future<void> Function() exitForUpdate,
  required VoidCallback openPairing,
  required VoidCallback openShareLinks,
  @visibleForTesting SettingsScreen Function(SettingsLayout layout)? screen,
}) async {
  if (_open?.isActive ?? false) return;
  SettingsScreen build(SettingsLayout layout) =>
      screen?.call(layout) ??
      SettingsScreen(
        layout: layout,
        exitForUpdate: exitForUpdate,
        openPairing: openPairing,
        openShareLinks: openShareLinks,
      );
  if (ShellContent.attached) {
    await ShellContent.pushTop<void>((_) => build(SettingsLayout.page));
    return;
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final Route<void> route = MediaQuery.sizeOf(context).width < 600
      ? WhisperPageRoute<void>(builder: (_) => build(SettingsLayout.page))
      : WhisperModalRoute<void>(
          scrim: context.wc.scrim,
          barrierLabel: MaterialLocalizations.of(
            context,
          ).modalBarrierDismissLabel,
          builder: (_) => build(SettingsLayout.panel),
        );
  _open = route;
  await navigator.push(route);
}
