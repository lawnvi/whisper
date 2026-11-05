import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/toast.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/app_health.dart';
import 'package:whisper/state/diagnostic_report.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// What to say about a problem, on the island and here.
String appProblemText(AppLocalizations l10n, AppProblem problem) =>
    switch (problem) {
      AppProblem.database => l10n.healthDatabase,
      AppProblem.startup => l10n.healthStartup,
      AppProblem.server => l10n.healthServer,
      AppProblem.discovery => l10n.healthDiscovery,
    };

Future<void> showDiagnostics(BuildContext context) => showShellSheet<void>(
  context,
  scrolls: false,
  builder: (context) => const ShellDiagnostics(),
);

/// surfaces.md「诊断信息」: whether Whisper is working, and what to send when it
/// is not.
class ShellDiagnostics extends StatefulWidget {
  const ShellDiagnostics({super.key});

  @override
  State<ShellDiagnostics> createState() => _ShellDiagnosticsState();
}

class _ShellDiagnosticsState extends State<ShellDiagnostics> {
  static final _issues = Uri.https('github.com', '/lawnvi/whisper/issues/new');

  String? _address;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final address = await getLocalIpAddress();
    if (mounted) setState(() => _address = address);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: await buildDiagnosticReport()));
    if (mounted) showAppToast(AppLocalizations.of(context)!.diagCopied);
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final report = Uint8List.fromList(
      utf8.encode(await buildDiagnosticReport()),
    );
    final path = await FilePicker.saveFile(
      dialogTitle: l10n.diagSave,
      fileName: 'whisper-diagnostics.txt',
      initialDirectory: await LocalSetting().saveDialogFolder(),
      bytes: report,
    );
    if (path == null) return;
    if (isDesktop()) await File(path).writeAsBytes(report);
    showAppToast(l10n.diagSaved);
  }

  /// The report goes on the clipboard, to paste there.
  Future<void> _feedback() async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: await buildDiagnosticReport()));
    await launchUrl(_issues, mode: LaunchMode.externalApplication);
    showAppToast(l10n.diagFeedbackCopied);
  }

  Future<void> _while(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error, stack) {
      AppHealth.shared.report(AppProblem.startup, error, stack);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    const type = WhisperType(touch: false);
    return ListenableBuilder(
      listenable: AppHealth.shared,
      builder: (context, _) {
        final health = AppHealth.shared;
        Widget state(bool ok) => Text(
          ok ? l10n.diagOk : l10n.diagFailed,
          style: TextStyle(fontSize: type.note, color: ok ? c.ink2 : c.warn),
        );
        final databaseOk = !health.has(AppProblem.database);
        return ShellSheetBody(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.diagTitle,
                style: TextStyle(
                  fontSize: type.title,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                  color: c.ink,
                ),
              ),
              const SizedBox(height: 12),
              for (final problem in health.problems) ...[
                Text(
                  appProblemText(l10n, problem),
                  style: TextStyle(
                    fontSize: type.body,
                    height: 1.45,
                    color: c.warn,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              if (health.problems.isNotEmpty) ...[
                Text(
                  l10n.diagRestartHint,
                  style: TextStyle(
                    fontSize: type.note,
                    height: 1.45,
                    color: c.ink2,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              ShellGroup(
                flat: true,
                children: [
                  ShellRow(
                    label: l10n.diagDatabase,
                    trailing: state(databaseOk),
                  ),
                  ShellRow(
                    label: l10n.diagServer,
                    trailing: state(
                      WsSvrManager().started && !health.has(AppProblem.server),
                    ),
                  ),
                  ShellRow(
                    label: l10n.diagDiscovery,
                    trailing: state(
                      databaseOk &&
                          !health.has(AppProblem.startup) &&
                          !health.has(AppProblem.discovery),
                    ),
                  ),
                  ShellRow(
                    label: l10n.shellSelfAddress,
                    trailing: Text(
                      _address ?? '—',
                      style: TextStyle(fontSize: type.note, color: c.ink2),
                    ),
                  ),
                ],
              ),
              if (health.oldHistoryUnreadable) ...[
                const SizedBox(height: 10),
                Text(
                  l10n.diagOldHistory,
                  style: TextStyle(
                    fontSize: type.note,
                    height: 1.45,
                    color: c.ink2,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                l10n.diagPrivacy,
                style: TextStyle(
                  fontSize: type.note,
                  height: 1.45,
                  color: c.ink2,
                ),
              ),
            ],
          ),
          actions: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ShellButton(
                label: l10n.diagFeedback,
                onTap: _busy ? null : () => unawaited(_while(_feedback)),
              ),
              const Spacer(),
              ShellButton(
                label: l10n.diagSave,
                onTap: _busy ? null : () => unawaited(_while(_save)),
              ),
              const SizedBox(width: 8),
              ShellButton(
                label: l10n.diagCopy,
                onTap: _busy ? null : () => unawaited(_while(_copy)),
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
      },
    );
  }
}
