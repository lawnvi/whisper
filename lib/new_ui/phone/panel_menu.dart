import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// One row of a [showPanelMenu]: what the prototype's `showMenu` takes.
class PanelMenuEntry {
  const PanelMenuEntry({
    required this.label,
    this.onSelected,
    this.leading,
    this.glyph,
    this.checked = false,
    this.danger = false,
    this.enabled = true,
    this.indent = false,
    this.key,
    this.trailing,
  }) : separator = false;

  const PanelMenuEntry.separator()
    : label = '',
      onSelected = null,
      leading = null,
      glyph = null,
      checked = false,
      danger = false,
      enabled = false,
      indent = false,
      key = null,
      trailing = null,
      separator = true;

  final String label;
  final VoidCallback? onSelected;

  /// A line glyph at 20, which goes white with the row.
  final Widget Function(Color color)? leading;
  final WhisperGlyph? glyph;
  final bool checked, danger, enabled, separator;

  /// Lines up with the text of the rows that have a glyph.
  final bool indent;
  final Key? key;

  /// Instead of the tick.
  final Widget Function(Color color)? trailing;
}

/// `.menu`: `panel` glass, at least 210 wide and at most 320, corners of `m`,
/// grown out of the button at [anchor]. Rows are 30 high, 48 when [touch], with
/// [title] in `tiny` above them. It goes above the button when it does not fit
/// under it, and scrolls when it fits in neither place.
Future<void> showPanelMenu(
  BuildContext context, {
  required Rect anchor,
  required List<PanelMenuEntry> items,
  String? title,
  bool touch = false,
}) async {
  final picked = await Navigator.of(context, rootNavigator: true)
      .push<PanelMenuEntry>(
        WhisperModalRoute<PanelMenuEntry>(
          style: WhisperModalStyle.menu,
          alignment: Alignment.topCenter,
          barrierLabel: MaterialLocalizations.of(
            context,
          ).modalBarrierDismissLabel,
          builder: (_) => PanelMenu(
            anchor: anchor,
            items: items,
            title: title,
            touch: touch,
          ),
        ),
      );
  picked?.onSelected?.call();
}

/// Where [context]'s box is, in the coordinates of the root overlay.
Rect panelMenuAnchor(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(context, rootNavigator: true).context.findRenderObject()!
          as RenderBox;
  return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
}

class PanelMenu extends StatelessWidget {
  const PanelMenu({
    super.key,
    required this.anchor,
    required this.items,
    this.title,
    this.touch = false,
  });

  final Rect anchor;
  final List<PanelMenuEntry> items;
  final String? title;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final c = context.wc;
    final type = WhisperType(touch: touch);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(WhisperRadius.m),
    );
    final title = this.title;
    return CustomSingleChildLayout(
      delegate: _MenuPosition(anchor),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 210, maxWidth: 320),
        child: IntrinsicWidth(
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: shape,
              shadows: WhisperShadow.e2(brightness),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: WhisperGlass(
                kind: GlassKind.panel,
                shape: shape,
                child: CustomPaint(
                  foregroundPainter: PanelEdge(
                    radius: WhisperRadius.m,
                    color: WhisperShadow.highlight(brightness),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(5),
                    child: FocusTraversalGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (title != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(9, 5, 9, 4),
                              child: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: type.tiny,
                                  fontWeight: FontWeight.w500,
                                  color: c.ink2Glass,
                                ),
                              ),
                            ),
                          for (final item in items)
                            item.separator
                                ? Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 5,
                                    ),
                                    child: SizedBox(
                                      height:
                                          1 /
                                          MediaQuery.devicePixelRatioOf(
                                            context,
                                          ),
                                      child: ColoredBox(color: c.sep),
                                    ),
                                  )
                                : PanelMenuRow(
                                    key: item.key,
                                    item: item,
                                    touch: touch,
                                    onTap: item.enabled
                                        ? () => Navigator.of(context).pop(item)
                                        : null,
                                  ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.mi`: hover or press turns it `accent` with white text.
class PanelMenuRow extends StatefulWidget {
  const PanelMenuRow({
    super.key,
    required this.item,
    required this.onTap,
    this.touch = false,
  });

  final PanelMenuEntry item;
  final VoidCallback? onTap;
  final bool touch;

  @override
  State<PanelMenuRow> createState() => _PanelMenuRowState();
}

class _PanelMenuRowState extends State<PanelMenuRow> {
  bool _hover = false, _down = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final item = widget.item;
    final type = WhisperType(touch: widget.touch);
    final enabled = widget.onTap != null;
    final lit = enabled && (_hover || _down || _focused);
    final tint = item.danger ? c.bad : c.accent;
    final Color ink = lit
        ? c.onAccent
        : !enabled
        ? c.ink3
        : item.danger
        ? c.bad
        : c.ink;
    final Color mark = lit ? c.onAccent : (enabled ? c.accent : c.ink3);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: item.checked,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: SystemMouseCursors.basic,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: Container(
            constraints: BoxConstraints(minHeight: widget.touch ? 48 : 30),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: lit ? tint : Colors.transparent,
              borderRadius: BorderRadius.circular(WhisperRadius.xs),
            ),
            child: Row(
              children: [
                if (item.leading != null) ...[
                  SizedBox(width: 20, child: item.leading!(mark)),
                  const SizedBox(width: 9),
                ] else if (item.glyph != null) ...[
                  WhisperIcon(item.glyph!, size: 15, color: mark),
                  const SizedBox(width: 9),
                ] else if (item.indent)
                  const SizedBox(width: 29),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: type.body,
                      height: 1.3,
                      color: ink,
                    ),
                  ),
                ),
                if (item.checked) ...[
                  const SizedBox(width: 9),
                  item.trailing?.call(ink) ??
                      WhisperIcon(
                        WhisperGlyph.check,
                        size: 13,
                        weight: 2,
                        color: ink,
                      ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The hairline along the top of raised glass, which follows its corners.
class PanelEdge extends CustomPainter {
  const PanelEdge({required this.radius, required this.color});

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, radius / 2));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(.25),
        Radius.circular(radius),
      ),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = .5,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(PanelEdge old) =>
      old.radius != radius || old.color != color;
}

/// Under its button, centred on it and kept 10 inside the window; above it when
/// it does not fit under.
class _MenuPosition extends SingleChildLayoutDelegate {
  const _MenuPosition(this.anchor);

  final Rect anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.min(320.0, constraints.maxWidth - 20),
        maxHeight: math.max(0.0, constraints.maxHeight - 20),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (anchor.center.dx - child.width / 2)
        .clamp(10.0, math.max(10.0, size.width - child.width - 10))
        .toDouble();
    var y = anchor.bottom + 6;
    if (y + child.height > size.height - 10) {
      y = math.max(10.0, anchor.top - child.height - 6);
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuPosition old) => old.anchor != anchor;
}
