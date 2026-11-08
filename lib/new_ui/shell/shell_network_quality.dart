import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/state/peer_link_quality.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// The device card's「网络」row for a connected device: how good the link
/// is, measured while the card is open. It opens the details.
class ShellNetworkRow extends StatefulWidget {
  const ShellNetworkRow({
    super.key,
    required this.device,
    this.touch = false,
    this.quality,
  });

  final DeviceData device;
  final bool touch;

  /// Measured elsewhere (previews); otherwise the row measures while shown.
  final PeerLinkQuality? quality;

  @override
  State<ShellNetworkRow> createState() => _ShellNetworkRowState();
}

class _ShellNetworkRowState extends State<ShellNetworkRow> {
  late final PeerLinkQuality _quality =
      widget.quality ??
      (PeerLinkQuality(host: widget.device.host, port: widget.device.port)
        ..start());

  @override
  void dispose() {
    if (widget.quality == null) _quality.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: _quality,
      builder: (context, _) => ShellRow(
        touch: widget.touch,
        label: l10n.shellCardNetwork,
        trailing: _GradeMark(quality: _quality, touch: widget.touch),
        chevron: true,
        onTap: () => showShellSheet<void>(
          context,
          scrolls: false,
          builder: (context) => _NetworkSheet(
            device: widget.device,
            quality: _quality,
            touch: widget.touch,
          ),
        ),
      ),
    );
  }
}

String _gradeText(AppLocalizations l10n, LinkGrade grade) => switch (grade) {
  LinkGrade.measuring => l10n.networkGradeMeasuring,
  LinkGrade.good => l10n.networkGradeGood,
  LinkGrade.fair => l10n.networkGradeFair,
  LinkGrade.poor => l10n.networkGradePoor,
  LinkGrade.unreachable => l10n.networkGradeUnreachable,
};

Color? _gradeColor(WhisperColors c, LinkGrade grade) => switch (grade) {
  LinkGrade.measuring => null,
  LinkGrade.good => c.ok,
  LinkGrade.fair => c.warn,
  LinkGrade.poor || LinkGrade.unreachable => c.bad,
};

/// The same dot as before a device row's status in the sidebar.
const _dot = 7.0;

String _ms(Duration? value) =>
    value == null ? '—' : '${(value.inMicroseconds / 1000).round()} ms';

/// A dot in the grade's colour, the grade in words and the usual round trip.
class _GradeMark extends StatelessWidget {
  const _GradeMark({
    required this.quality,
    required this.touch,
    this.withLatency = true,
  });

  final PeerLinkQuality quality;
  final bool touch;

  /// The details list the latency on a row of its own.
  final bool withLatency;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    final grade = quality.grade;
    final color = _gradeColor(c, grade);
    final latency = quality.latency;
    final words =
        !withLatency || grade == LinkGrade.measuring || latency == null
        ? _gradeText(l10n, grade)
        : '${_gradeText(l10n, grade)} · ${_ms(latency)}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (color != null) ...[
          Container(
            width: _dot,
            height: _dot,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
        ],
        Text(
          words,
          style: TextStyle(
            fontSize: WhisperType(touch: touch).note,
            color: c.ink2,
          ),
        ),
      ],
    );
  }
}

class _NetworkSheet extends StatelessWidget {
  const _NetworkSheet({
    required this.device,
    required this.quality,
    required this.touch,
  });

  final DeviceData device;
  final PeerLinkQuality quality;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    final type = WhisperType(touch: touch);
    return ListenableBuilder(
      listenable: quality,
      builder: (context, _) {
        final grade = quality.grade;
        final verdict = switch (grade) {
          LinkGrade.measuring => l10n.networkVerdictMeasuring,
          LinkGrade.good => l10n.networkVerdictGood,
          LinkGrade.fair => l10n.networkVerdictFair,
          LinkGrade.poor => l10n.networkVerdictPoor,
          LinkGrade.unreachable => l10n.networkVerdictUnreachable,
        };
        final measured = grade != LinkGrade.measuring;
        return ShellSheetBody(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.networkTitle,
                style: TextStyle(
                  fontSize: type.head,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: c.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${device.name} · ${device.host}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: type.note, color: c.ink2),
              ),
              const SizedBox(height: 14),
              ShellGroup(
                children: [
                  ShellRow(
                    touch: touch,
                    label: l10n.networkGrade,
                    trailing: _GradeMark(
                      quality: quality,
                      touch: touch,
                      withLatency: false,
                    ),
                  ),
                  ShellRow(
                    touch: touch,
                    label: l10n.networkLatency,
                    trailing: _Value(_ms(quality.latency), touch: touch),
                  ),
                  ShellRow(
                    touch: touch,
                    label: l10n.networkJitter,
                    trailing: _Value(_ms(quality.jitter), touch: touch),
                  ),
                  ShellRow(
                    touch: touch,
                    label: l10n.networkLoss,
                    trailing: _Value(
                      measured ? '${(quality.loss * 100).round()}%' : '—',
                      touch: touch,
                    ),
                  ),
                ],
              ),
              // The sheet keeps its height while the words change.
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 36),
                child: Text(
                  verdict,
                  style: TextStyle(
                    fontSize: type.note,
                    height: 1.45,
                    color: c.ink2,
                  ),
                ),
              ),
            ],
          ),
          actions: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ShellFilledButton(
                label: l10n.close,
                touch: touch,
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.text, {required this.touch});

  final String text;
  final bool touch;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: WhisperType(touch: touch).note,
      color: context.wc.ink2,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}
