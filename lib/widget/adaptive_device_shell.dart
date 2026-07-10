import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AdaptiveDeviceShell extends StatelessWidget {
  const AdaptiveDeviceShell({
    super.key,
    required this.workbench,
    required this.detail,
    required this.emptyDetail,
    required this.backLabel,
    required this.onBack,
  });

  static const workbenchPaneKey =
      ValueKey<String>('adaptive-device-workbench-pane');
  static const detailPaneKey = ValueKey<String>('adaptive-device-detail-pane');
  static const backButtonKey = ValueKey<String>('adaptive-device-back-button');

  final Widget workbench;
  final Widget? detail;
  final Widget emptyDetail;
  final String backLabel;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < WhisperUi.compactWindowBreakpoint) {
          if (detail == null) {
            return KeyedSubtree(
              key: workbenchPaneKey,
              child: workbench,
            );
          }
          return KeyedSubtree(
            key: detailPaneKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _CompactBackAction(label: backLabel, onPressed: onBack),
                Expanded(child: detail!),
              ],
            ),
          );
        }

        final palette = context.whisperPalette;
        final workbenchWidth = _workbenchWidth(constraints.maxWidth);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              key: workbenchPaneKey,
              width: workbenchWidth,
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                border: Border(
                  right: BorderSide(color: palette.borderSubtle),
                ),
              ),
              child: workbench,
            ),
            Expanded(
              key: detailPaneKey,
              child: detail ?? emptyDetail,
            ),
          ],
        );
      },
    );
  }

  double _workbenchWidth(double availableWidth) {
    if (availableWidth >= WhisperUi.expandedWindowBreakpoint) {
      return 340;
    }
    return (availableWidth * 0.34).clamp(288, 312).toDouble();
  }
}

class _CompactBackAction extends StatefulWidget {
  const _CompactBackAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<_CompactBackAction> createState() => _CompactBackActionState();
}

class _CompactBackActionState extends State<_CompactBackAction> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        border: Border(bottom: BorderSide(color: palette.borderSubtle)),
      ),
      child: Semantics(
        excludeSemantics: true,
        button: true,
        enabled: true,
        focusable: true,
        label: widget.label,
        onFocus: _focusNode.requestFocus,
        onTap: widget.onPressed,
        child: Tooltip(
          message: widget.label,
          child: InkWell(
            key: AdaptiveDeviceShell.backButtonKey,
            focusNode: _focusNode,
            onTap: widget.onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: WhisperUi.minInteractiveSize,
              ),
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: <Widget>[
                    const SizedBox.square(
                      dimension: WhisperUi.minInteractiveSize,
                      child: Icon(Icons.arrow_back_rounded, size: 20),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
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
