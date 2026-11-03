import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/state/connection_check.dart';
import 'package:whisper/state/connection_diagnostic.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// docs/design/surfaces.md「连接诊断」: really looks, and says what it found.
Future<void> showConnectionCheck(
  BuildContext context, {
  required DeviceData device,
  required bool Function() connected,
  required VoidCallback onConnect,
  bool touch = false,
  ConnectionProbe? probe,
}) => showShellSheet<void>(
  context,
  scrolls: false,
  builder: (context) => ConnectionCheckSheet(
    device: device,
    connected: connected,
    onConnect: onConnect,
    touch: touch,
    probe: probe ?? ConnectionProbe.live(),
  ),
);

class ConnectionCheckSheet extends StatefulWidget {
  const ConnectionCheckSheet({
    super.key,
    required this.device,
    required this.connected,
    required this.onConnect,
    required this.probe,
    this.touch = false,
  });

  final DeviceData device;
  final bool Function() connected;
  final VoidCallback onConnect;
  final ConnectionProbe probe;
  final bool touch;

  @override
  State<ConnectionCheckSheet> createState() => _ConnectionCheckSheetState();
}

class _ConnectionCheckSheetState extends State<ConnectionCheckSheet> {
  StreamSubscription<ConnectionCheckReport>? _run;
  ConnectionCheckReport? _report;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    unawaited(_run?.cancel());
    super.dispose();
  }

  void _start() {
    unawaited(_run?.cancel());
    _run =
        checkConnection(
          host: widget.device.host,
          port: widget.device.port,
          connected: widget.connected,
          probe: widget.probe,
        ).listen((report) {
          if (mounted) setState(() => _report = report);
        });
  }

  String _problemText(AppLocalizations l10n, ConnectionDiagnosticStage stage) =>
      switch (stage) {
        ConnectionDiagnosticStage.wifi => l10n.connectionDiagnosticWifi,
        ConnectionDiagnosticStage.address => l10n.connectionDiagnosticAddress,
        ConnectionDiagnosticStage.service => l10n.connectionDiagnosticService,
        ConnectionDiagnosticStage.firewall => l10n.connectionDiagnosticFirewall,
        ConnectionDiagnosticStage.identity => l10n.connectionDiagnosticIdentity,
        ConnectionDiagnosticStage.version => l10n.connectionDiagnosticVersion,
        ConnectionDiagnosticStage.pairing => l10n.connectionDiagnosticPairing,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final touch = widget.touch;
    final type = WhisperType(touch: touch);
    final device = widget.device;
    final report = _report;
    final finished = report?.finished ?? false;
    final String? summary = !finished
        ? null
        : report!.oneWay
        ? l10n.connectionCheckOneWay
        : report.connected
        ? l10n.connectionCheckConnected
        : report.problem != null
        ? _problemText(l10n, report.problem!)
        : l10n.connectionCheckReady;
    final bad = finished && !report!.connected && report.problem != null;
    final labels = {
      ConnectionCheckStep.network: l10n.connectionCheckNetwork,
      ConnectionCheckStep.address: l10n.connectionCheckAddress,
      ConnectionCheckStep.service: l10n.connectionCheckService,
      ConnectionCheckStep.session: l10n.connectionCheckSession,
    };
    return ShellSheetBody(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.connectionDiagnosticTitle,
            style: TextStyle(
              fontSize: type.head,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${device.name} · ${device.host}:${device.port}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: type.note, color: c.ink2),
          ),
          const SizedBox(height: 14),
          ShellGroup(
            children: [
              for (final step in ConnectionCheckStep.values)
                ShellRow(
                  touch: touch,
                  label: labels[step]!,
                  trailing: _StepMark(
                    state: report?.states[step] ?? ConnectionCheckState.waiting,
                    detail: switch (step) {
                      ConnectionCheckStep.service when report?.reach != null =>
                        '${report!.reach!.inMilliseconds} ms',
                      ConnectionCheckStep.session
                          when report?.states[step] ==
                              ConnectionCheckState.idle =>
                        l10n.connectionCheckNotConnected,
                      _ => null,
                    },
                  ),
                ),
            ],
          ),
          // The sheet keeps its height while the words arrive.
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Text(
              summary ?? '',
              style: TextStyle(
                fontSize: type.note,
                height: 1.45,
                color: bad ? c.bad : c.ink2,
              ),
            ),
          ),
        ],
      ),
      actions: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ShellButton(
            label: l10n.connectionCheckAgain,
            touch: touch,
            large: true,
            onTap: finished ? _start : null,
          ),
          const SizedBox(width: 8),
          if (finished && !report!.connected)
            ShellFilledButton(
              label: l10n.shellConnect,
              touch: touch,
              onTap: () {
                Navigator.of(context).pop();
                widget.onConnect();
              },
            )
          else
            ShellFilledButton(
              label: l10n.close,
              touch: touch,
              onTap: () => Navigator.of(context).pop(),
            ),
        ],
      ),
    );
  }
}

class _StepMark extends StatelessWidget {
  const _StepMark({required this.state, this.detail});

  final ConnectionCheckState state;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final mark = switch (state) {
      ConnectionCheckState.checking => SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: c.ink2),
      ),
      ConnectionCheckState.passed => WhisperIcon(
        WhisperGlyph.check,
        size: 15,
        weight: 2.2,
        color: c.ok,
      ),
      ConnectionCheckState.failed => WhisperIcon(
        WhisperGlyph.warn,
        size: 15,
        color: c.bad,
      ),
      ConnectionCheckState.idle || ConnectionCheckState.waiting => Text(
        '—',
        style: TextStyle(fontSize: 13, color: c.ink3),
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (detail case final text?) ...[
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: c.ink2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 6),
        ],
        SizedBox(width: 16, child: Center(child: mark)),
      ],
    );
  }
}
