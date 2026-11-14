import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

import 'settings_rows.dart';

class SettingsMenuItem<T> {
  const SettingsMenuItem(this.value, this.label);

  final T value;
  final String label;
}

/// 4 or more choices: writes the current one, and opens a menu with a tick.
class SettingsPopupButton<T> extends StatelessWidget {
  const SettingsPopupButton({
    super.key,
    required this.title,
    required this.items,
    required this.selected,
    required this.onSelected,
  });

  /// What is being chosen, for screen readers.
  final String title;
  final List<SettingsMenuItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;

  Future<void> _open(BuildContext context) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final box = context.findRenderObject()! as RenderBox;
    final overlay = navigator.context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final picked = await navigator.push<_Picked<T>>(
      WhisperModalRoute<_Picked<T>>(
        style: WhisperModalStyle.menu,
        alignment: Alignment.topCenter,
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        builder: (_) => SettingsScope(
          touch: SettingsScope.of(context).touch,
          page: SettingsScope.of(context).page,
          child: _Menu<T>(anchor: anchor, items: items, selected: selected),
        ),
      ),
    );
    if (picked != null) onSelected(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final touch = SettingsScope.of(context).touch;
    final type = SettingsScope.typeOf(context);
    final current = items.firstWhere((item) => item.value == selected).label;
    return Pressable(
      radius: WhisperRadius.s,
      label: '$title, $current',
      onTap: () => unawaited(_open(context)),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: touch ? 7 : 0),
        child: SettingsHighlight(
          base: c.fill,
          hover: c.fill2,
          radius: WhisperRadius.s,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: touch ? 34 : 28),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(11, 0, 8, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      current,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.note,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  WhisperIcon(
                    WhisperGlyph.updown,
                    size: 12,
                    weight: 2,
                    color: c.ink2,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A choice made in a menu; dismissing it makes none. Tells "picked null"
/// (the system's language) apart from "picked nothing".
class _Picked<T> {
  const _Picked(this.value);

  final T value;
}

class _Menu<T> extends StatelessWidget {
  const _Menu({
    required this.anchor,
    required this.items,
    required this.selected,
  });

  final Rect anchor;
  final List<SettingsMenuItem<T>> items;
  final T selected;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(WhisperRadius.m),
    );
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
                child: SettingsTextStyle(
                  child: CustomPaint(
                    foregroundPainter: SettingsGlassEdge(
                      radius: WhisperRadius.m,
                      color: WhisperShadow.highlight(brightness),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: FocusTraversalGroup(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final item in items)
                              _MenuRow<T>(item: item, selected: selected),
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
      ),
    );
  }
}

/// The hairline along the top of raised glass, which follows its corners.
class SettingsGlassEdge extends CustomPainter {
  const SettingsGlassEdge({required this.radius, required this.color});

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
  bool shouldRepaint(SettingsGlassEdge old) =>
      old.radius != radius || old.color != color;
}

/// Under its button, centred on it, and always inside the window.
class _MenuPosition extends SingleChildLayoutDelegate {
  const _MenuPosition(this.anchor);

  final Rect anchor;

  static const _margin = 10.0, _gap = 6.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (anchor.center.dx - child.width / 2)
        .clamp(_margin, math.max(_margin, size.width - child.width - _margin))
        .toDouble();
    final below = anchor.bottom + _gap;
    final y = below + child.height <= size.height - _margin
        ? below
        : math.max(_margin, anchor.top - _gap - child.height);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuPosition old) => old.anchor != anchor;
}

class _MenuRow<T> extends StatefulWidget {
  const _MenuRow({required this.item, required this.selected});

  final SettingsMenuItem<T> item;
  final T selected;

  @override
  State<_MenuRow<T>> createState() => _MenuRowState<T>();
}

class _MenuRowState<T> extends State<_MenuRow<T>> {
  bool _hovered = false, _focused = false;

  void _pick() => Navigator.of(context).pop(_Picked<T>(widget.item.value));

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final touch = SettingsScope.of(context).touch;
    final type = SettingsScope.typeOf(context);
    final isSelected = widget.item.value == widget.selected;
    final lit = _hovered || _focused;
    return Semantics(
      button: true,
      selected: isSelected,
      child: FocusableActionDetector(
        autofocus: isSelected,
        mouseCursor: SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _pick();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _pick,
          child: Container(
            constraints: BoxConstraints(minHeight: touch ? 48 : 30),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: lit ? c.accent : null,
              borderRadius: BorderRadius.circular(WhisperRadius.menuRow),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.item.label,
                    style: TextStyle(
                      fontSize: type.body,
                      color: lit ? c.onAccent : c.ink,
                    ),
                  ),
                ),
                if (isSelected) ...[
                  const SizedBox(width: 9),
                  WhisperIcon(
                    WhisperGlyph.check,
                    size: 13,
                    weight: 2,
                    color: lit ? c.onAccent : c.ink,
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
