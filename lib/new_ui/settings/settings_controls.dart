import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/desktop_screenshot.dart';
import 'package:whisper/helper/screenshot_shortcut.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// What the settings are laid out with (docs/design/surfaces.md「设置」). None
/// of this knows about any one setting: lib/page/settings.dart says what is in
/// each row and what it does.

/// Whether the rows around here are for a finger, and whether they are on the
/// phone's one long page or in the desktop's panel.
class SettingsScope extends InheritedWidget {
  const SettingsScope({
    super.key,
    required this.touch,
    required this.page,
    required super.child,
  });

  /// Text and targets for a finger.
  final bool touch;

  /// The phone's page: groups have lines and a shadow, and a slider gets a line
  /// of its own. The desktop's panel has neither.
  final bool page;

  static SettingsScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsScope>()!;

  @override
  bool updateShouldNotify(SettingsScope old) =>
      touch != old.touch || page != old.page;
}

WhisperType _type(BuildContext context) =>
    WhisperType(touch: SettingsScope.of(context).touch);

/// The theme's body style has Material's letter spacing, which spreads Chinese
/// out, and puts the extra line height above the text instead of around it.
/// Everything in the settings is under this.
class SettingsTextStyle extends StatelessWidget {
  const SettingsTextStyle({super.key, required this.child});

  static const style = TextStyle(
    letterSpacing: 0,
    leadingDistribution: TextLeadingDistribution.even,
  );

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      DefaultTextStyle.merge(style: style, child: child);
}

/// A colour that follows the pointer: [hover] under it, [press] while down.
/// Springs, so it never jumps. What a touch screen does not have, it never
/// shows.
class SettingsHighlight extends StatefulWidget {
  const SettingsHighlight({
    super.key,
    required this.child,
    this.base,
    this.hover,
    this.press,
    this.radius = 0,
  });

  final Widget child;
  final Color? base, hover, press;
  final double radius;

  @override
  State<SettingsHighlight> createState() => _SettingsHighlightState();
}

class _SettingsHighlightState extends State<SettingsHighlight> {
  bool _hovered = false, _down = false;

  void _setDown(bool down) {
    if (down != _down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Listener(
      onPointerDown: (_) => _setDown(true),
      onPointerUp: (_) => _setDown(false),
      onPointerCancel: (_) => _setDown(false),
      child: SpringBuilder(
        value: _hovered ? 1 : 0,
        spring: WhisperSprings.snappy,
        animateWhenReduced: true,
        child: widget.child,
        builder: (context, h, child) => SpringBuilder(
          value: _down ? 1 : 0,
          spring: WhisperSprings.snappy,
          animateWhenReduced: true,
          child: child,
          builder: (context, p, child) {
            final hover = widget.hover ?? widget.base;
            final over = Color.lerp(widget.base, hover, h.clamp(0.0, 1.0));
            final color = widget.press == null
                ? over
                : Color.lerp(over, widget.press, p.clamp(0.0, 1.0));
            return DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(widget.radius),
              ),
              child: child,
            );
          },
        ),
      ),
    ),
  );
}

/// The white paper the rows sit on. In the panel it has no lines and no shadow;
/// on the page lines start where the text starts.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final page = SettingsScope.of(context).page;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(WhisperRadius.m),
    );
    final rows = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, child) in children.indexed)
          _RowLine(show: page && i > 0, child: child),
      ],
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: c.group,
        shape: shape,
        shadows: page ? WhisperShadow.e1(Theme.of(context).brightness) : null,
      ),
      // A pressed or hovered row must not reach past the corners.
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: page
            ? rows
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: rows,
              ),
      ),
    );
  }
}

/// Each row draws its own line, so a row that turns out to have nothing to show
/// leaves no doubled line behind.
class _RowLine extends InheritedWidget {
  const _RowLine({required this.show, required super.child});

  final bool show;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RowLine>()?.show ?? false;

  @override
  bool updateShouldNotify(_RowLine old) => show != old.show;
}

class _TopLine extends CustomPainter {
  const _TopLine({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(_rowInsetPage, 0, size.width - _rowInsetPage, width),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_TopLine old) => old.color != color || old.width != width;
}

const _rowInsetPage = 12.0;
const _rowInsetPanel = 14.0;

/// The height, the padding and the line every row shares.
class SettingsRowFrame extends StatelessWidget {
  const SettingsRowFrame({
    super.key,
    required this.child,
    this.minHeight,
    this.vertical,
    this.inset,
  });

  final Widget child;
  final double? minHeight, vertical, inset;

  @override
  Widget build(BuildContext context) {
    final scope = SettingsScope.of(context);
    final frame = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: minHeight ?? (scope.touch ? 48 : 44),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: inset ?? (scope.page ? _rowInsetPage : _rowInsetPanel),
          vertical: vertical ?? (scope.touch ? 0 : 6),
        ),
        child: child,
      ),
    );
    if (!_RowLine.of(context)) return frame;
    return CustomPaint(
      foregroundPainter: _TopLine(
        color: context.wc.sep,
        width: 1 / MediaQuery.devicePixelRatioOf(context),
      ),
      child: frame,
    );
  }
}

/// A title, and maybe a line under it. Never squeezed out of a row: long ones
/// wrap, because a setting's name is what the row is.
class SettingsRowTitle extends StatelessWidget {
  const SettingsRowTitle({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = _type(context);
    return Padding(
      // On a touch row the frame has no padding of its own: its controls need
      // the whole height. Text that wraps still should not touch the edges.
      padding: EdgeInsets.symmetric(
        vertical: SettingsScope.of(context).touch ? 4 : 0,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: type.body, height: 1.3, color: c.ink),
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Text(
              subtitle!,
              style: TextStyle(fontSize: type.note, height: 1.3, color: c.ink2),
            ),
        ],
      ),
    );
  }
}

/// A row in a group. [trailing] stays beside the title and is never wider than
/// it can be: past 60% it has to give way, so a value can ellipsize and a
/// control cannot overflow.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.fillTrailing = false,
    this.stackWhenTight = false,
    this.minHeight,
    this.inset,
    this.below,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  /// The whole row does this, like a button.
  final VoidCallback? onTap, onLongPress;

  /// The title takes what it needs and [trailing] the rest: an inline field, a
  /// path.
  final bool fillTrailing;

  /// A control that cannot get narrower, like a segmented one, goes under the
  /// title when it does not fit beside it.
  final bool stackWhenTight;

  final double? minHeight, inset;

  /// Under the row, full width: a progress bar.
  final Widget? below;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final scope = SettingsScope.of(context);
    final heading = SettingsRowTitle(title: title, subtitle: subtitle);
    final Widget content;
    if (trailing == null) {
      content = Align(alignment: Alignment.centerLeft, child: heading);
    } else if (stackWhenTight) {
      // Align: an OverflowBar centres on its own height, not the row's.
      content = Align(
        child: OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          overflowAlignment: OverflowBarAlignment.end,
          spacing: 10,
          overflowSpacing: 4,
          children: [heading, trailing!],
        ),
      );
    } else {
      content = LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            if (fillTrailing)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * .5),
                child: heading,
              )
            else
              Expanded(child: heading),
            const SizedBox(width: 10),
            if (fillTrailing)
              Expanded(child: trailing!)
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * .6),
                child: trailing!,
              ),
          ],
        ),
      );
    }
    Widget row = SettingsRowFrame(
      minHeight: minHeight,
      inset: inset,
      child: content,
    );
    if (below != null) {
      row = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [row, below!],
      );
    }
    if (onTap == null && onLongPress == null) return row;
    row = Pressable(
      scale: 1,
      radius: scope.page ? 0 : WhisperRadius.xs,
      label: semanticLabel,
      onTap: onTap,
      child: SettingsHighlight(
        hover: scope.touch ? null : c.fill,
        press: scope.touch ? c.fill : c.fill2,
        child: row,
      ),
    );
    return onLongPress == null
        ? row
        : GestureDetector(onLongPress: onLongPress, child: row);
  }
}

/// A row that is a switch. The whole row flips it, as it always has here.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: subtitle == null ? title : '$title, $subtitle',
      enabled: onChanged != null,
      toggled: value,
      onTap: onChanged == null ? null : () => onChanged(!value),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: onChanged == null ? null : () => onChanged(!value),
        child: SettingsRow(
          title: title,
          subtitle: subtitle,
          trailing: Align(
            alignment: Alignment.centerRight,
            widthFactor: 1,
            child: WhisperSwitch(
              value: value,
              onChanged: onChanged,
              label: title,
            ),
          ),
        ),
      ),
    );
  }
}

/// What a row reads now, quiet, on the right.
class SettingsValue extends StatelessWidget {
  const SettingsValue(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.end,
    style: TextStyle(
      fontSize: _type(context).body,
      height: 1.3,
      fontWeight: color == null ? FontWeight.w400 : FontWeight.w500,
      color: color ?? context.wc.ink2,
    ),
  );
}

/// A value and the arrow to where it is changed.
class SettingsDisclosure extends StatelessWidget {
  const SettingsDisclosure({super.key, this.value});

  final String? value;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      if (value != null && value!.isNotEmpty) ...[
        Flexible(child: SettingsValue(value!)),
        const SizedBox(width: 10),
      ],
      // The stroke sits inside its box: moved over, it ends where a switch ends.
      Transform.translate(
        offset: const Offset(3, 0),
        child: WhisperIcon(
          WhisperGlyph.right,
          size: 13,
          weight: 2,
          color: context.wc.ink3,
        ),
      ),
    ],
  );
}

/// The small button of a settings row; light unless [filled].
class SettingsButton extends StatelessWidget {
  const SettingsButton({
    super.key,
    required this.label,
    required this.onTap,
    this.filled = false,
    this.large = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool filled, large;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final scope = SettingsScope.of(context);
    final type = _type(context);
    final height = scope.touch ? (large ? 48.0 : 44.0) : (large ? 36.0 : 28.0);
    final inset = scope.touch ? 16.0 : (large ? 20.0 : 13.0);
    return Pressable(
      onTap: onTap,
      radius: WhisperRadius.capsule,
      child: SettingsHighlight(
        base: filled ? c.accent : c.fill,
        hover: filled ? c.accent : c.fill2,
        press: filled ? c.accent : c.fill2,
        radius: WhisperRadius.capsule,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: large ? type.body : type.note,
                  fontWeight: FontWeight.w500,
                  color: filled ? c.onAccent : c.ink,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 2 or 3 choices. On a touch screen the visible control is 34 high and its
/// target is the row's height: taps in the bands above and below it pick the
/// segment they are over.
class SettingsSegmented<T> extends StatefulWidget {
  const SettingsSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final Map<T, String> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  State<SettingsSegmented<T>> createState() => _SettingsSegmentedState<T>();
}

class _SettingsSegmentedState<T> extends State<SettingsSegmented<T>> {
  final _keys = <T, GlobalKey>{};

  void _tapBand(TapUpDetails details) {
    for (final entry in _keys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final left = box.localToGlobal(Offset.zero).dx;
      final right = box.localToGlobal(box.size.topRight(Offset.zero)).dx;
      if (details.globalPosition.dx >= left &&
          details.globalPosition.dx <= right) {
        widget.onChanged(entry.key);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final touch = SettingsScope.of(context).touch;
    final type = _type(context);
    final fontSize = touch ? type.note : type.tiny;
    // The cells have a fixed height: with large text they have to grow with it.
    final lineHeight = MediaQuery.textScalerOf(context).scale(fontSize) * 1.5;
    final segmented = LiquidSegmented<T>(
      segments: widget.segments,
      selected: widget.selected,
      onChanged: widget.onChanged,
      labelKeys: _keys,
      height: math.max(touch ? 34 : 26, lineHeight + 8),
      fontSize: fontSize,
      minSegmentWidth: touch ? 40 : 32,
      segmentPadding: 9,
    );
    // Very large text on a narrow screen: smaller beats cut off.
    final fitted = FittedBox(fit: BoxFit.scaleDown, child: segmented);
    if (!touch) return fitted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _tapBand,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: fitted,
      ),
    );
  }
}

/// One thing a [SettingsPopupButton] offers.
@immutable
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
    final type = _type(context);
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
                    foregroundPainter: _GlassEdge(
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
class _GlassEdge extends CustomPainter {
  const _GlassEdge({required this.radius, required this.color});

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
  bool shouldRepaint(_GlassEdge old) =>
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
    final type = _type(context);
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

/// Text and numbers. With a pointer they are edited where they stand: Enter or
/// losing focus keeps what was typed, if it is valid; Esc puts back what was
/// there. On a phone the list only shows the value, and the row opens a page
/// for it, as the system's settings do for a device's name.
class SettingsFieldRow extends StatefulWidget {
  const SettingsFieldRow({
    super.key,
    required this.title,
    required this.value,
    required this.validate,
    required this.onCommit,
    required this.onInvalid,
    this.keyboardType,
    this.inputFormatters,
    this.hint,
  });

  final String title, value;

  /// Under the field on a phone's page: what the value is for.
  final String? hint;

  /// Why [String] cannot be used, or null when it can.
  final String? Function(String text) validate;
  final Future<void> Function(String text) onCommit;
  final ValueChanged<String> onInvalid;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<SettingsFieldRow> createState() => _SettingsFieldRowState();
}

class _SettingsFieldRowState extends State<SettingsFieldRow> {
  late final _controller = TextEditingController(text: widget.value);
  late final _focus = FocusNode(onKeyEvent: _onKey);
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(SettingsFieldRow old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    // Closing the page or changing section is losing focus too.
    if (_focus.hasFocus) _commit();
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() {});
    if (!_focus.hasFocus) _commit();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    // Handled on the way up too, or Esc would go on to close the panel.
    if (event is KeyDownEvent) {
      _controller.text = widget.value;
      node.unfocus();
    }
    return KeyEventResult.handled;
  }

  void _commit() {
    final text = _controller.text.trim();
    if (text == widget.value) {
      _controller.text = widget.value;
      return;
    }
    final problem = widget.validate(text);
    if (problem != null) {
      _controller.text = widget.value;
      widget.onInvalid(problem);
      return;
    }
    _controller.text = text;
    unawaited(widget.onCommit(text));
  }

  void _openPage() {
    unawaited(
      Navigator.of(context).push(
        WhisperPageRoute<void>(
          builder: (_) => _SettingsFieldPage(
            title: widget.title,
            value: widget.value,
            hint: widget.hint,
            validate: widget.validate,
            onCommit: widget.onCommit,
            keyboardType: widget.keyboardType,
            inputFormatters: widget.inputFormatters,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (SettingsScope.of(context).touch) {
      return SettingsRow(
        title: widget.title,
        fillTrailing: true,
        onTap: _openPage,
        trailing: SettingsDisclosure(value: widget.value),
      );
    }
    final c = context.wc;
    final type = _type(context);
    final focused = _focus.hasFocus;
    const none = InputBorder.none;
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      textAlign: TextAlign.end,
      textInputAction: TextInputAction.done,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      cursorColor: c.accent,
      cursorWidth: 1.5,
      style: SettingsTextStyle.style.copyWith(
        fontSize: type.body,
        height: 1.3,
        color: focused ? c.ink : c.ink2,
      ),
      decoration: const InputDecoration(
        isCollapsed: true,
        filled: false,
        border: none,
        enabledBorder: none,
        focusedBorder: none,
        disabledBorder: none,
        contentPadding: EdgeInsets.zero,
      ),
      onSubmitted: (_) => _focus.unfocus(),
    );
    return Semantics(
      container: true,
      textField: true,
      label: widget.title,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          // The row is the target, as a label is for its input.
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _focus.requestFocus,
          child: SettingsRow(
            title: widget.title,
            fillTrailing: true,
            trailing: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: SpringBuilder(
                  value: _hovered || focused ? 1 : 0,
                  spring: WhisperSprings.snappy,
                  animateWhenReduced: true,
                  child: field,
                  builder: (context, t, child) => Container(
                    constraints: const BoxConstraints(minHeight: 28),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    transform: Matrix4.translationValues(8, 0, 0),
                    alignment: Alignment.centerRight,
                    decoration: BoxDecoration(
                      color: Color.lerp(null, c.fill, t.clamp(0.0, 1.0)),
                      borderRadius: BorderRadius.circular(WhisperRadius.xs),
                      border: focused
                          ? Border.all(
                              color: c.accent.withValues(alpha: .35),
                              width: 3,
                              strokeAlign: BorderSide.strokeAlignOutside,
                            )
                          : null,
                    ),
                    child: child,
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

/// One value on a phone: its field, a way to clear it, and 完成 at the top, which
/// only lights up for something that can be kept. Going back keeps nothing.
class _SettingsFieldPage extends StatefulWidget {
  const _SettingsFieldPage({
    required this.title,
    required this.value,
    required this.validate,
    required this.onCommit,
    this.hint,
    this.keyboardType,
    this.inputFormatters,
  });

  final String title, value;
  final String? hint;
  final String? Function(String text) validate;
  final Future<void> Function(String text) onCommit;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<_SettingsFieldPage> createState() => _SettingsFieldPageState();
}

class _SettingsFieldPageState extends State<_SettingsFieldPage> {
  late final _controller = TextEditingController(text: widget.value)
    ..selection = TextSelection.collapsed(offset: widget.value.length);
  var _saving = false;

  String get _text => _controller.text.trim();

  /// Nothing typed yet is not a mistake: 完成 just stays off.
  String? get _problem => _text.isEmpty ? null : widget.validate(_text);

  bool get _canSave =>
      !_saving && _text.isNotEmpty && _text != widget.value && _problem == null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _leave() => unawaited(Navigator.of(context).maybePop());

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onCommit(_text);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (mounted) _leave();
  }

  void _submit() {
    if (_canSave) {
      unawaited(_save());
    } else if (_text == widget.value) {
      _leave();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final l10n = AppLocalizations.of(context)!;
    const none = InputBorder.none;
    return Scaffold(
      backgroundColor: c.canvas,
      body: SafeArea(
        bottom: false,
        child: SettingsScope(
          touch: true,
          page: true,
          child: SettingsTextStyle(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final problem = _problem;
                final note = problem ?? widget.hint;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: SizedBox(
                        height: 50,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 46),
                              child: Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: type.head,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600,
                                  color: c.ink,
                                ),
                              ),
                            ),
                            Pressable(
                              radius: WhisperRadius.capsule,
                              label: l10n.back,
                              onTap: _leave,
                              child: SizedBox.square(
                                dimension: 48,
                                child: Center(
                                  child: WhisperIcon(
                                    WhisperGlyph.back,
                                    size: 20,
                                    weight: 2,
                                    color: c.ink,
                                  ),
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: ShellButton(
                                label: l10n.shellDone,
                                kind: ShellButtonKind.quiet,
                                touch: true,
                                large: true,
                                inset: 12,
                                onTap: _canSave
                                    ? () => unawaited(_save())
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 620),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SettingsGroup(
                                  children: [
                                    SettingsRowFrame(
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Semantics(
                                              label: widget.title,
                                              child: TextField(
                                                controller: _controller,
                                                autofocus: true,
                                                textInputAction:
                                                    TextInputAction.done,
                                                keyboardType:
                                                    widget.keyboardType,
                                                inputFormatters:
                                                    widget.inputFormatters,
                                                cursorColor: c.accent,
                                                style: SettingsTextStyle.style
                                                    .copyWith(
                                                      fontSize: type.body,
                                                      height: 1.3,
                                                      color: c.ink,
                                                    ),
                                                decoration:
                                                    const InputDecoration(
                                                      isCollapsed: true,
                                                      filled: false,
                                                      border: none,
                                                      enabledBorder: none,
                                                      focusedBorder: none,
                                                      disabledBorder: none,
                                                      contentPadding:
                                                          EdgeInsets.zero,
                                                    ),
                                                // The keyboard stays until there
                                                // is somewhere to go.
                                                onEditingComplete: () {},
                                                onSubmitted: (_) => _submit(),
                                              ),
                                            ),
                                          ),
                                          Visibility(
                                            visible:
                                                _controller.text.isNotEmpty,
                                            maintainSize: true,
                                            maintainAnimation: true,
                                            maintainState: true,
                                            // The glyph ends where a row's
                                            // arrow and values end.
                                            child: Transform.translate(
                                              offset: const Offset(9, 0),
                                              child: Pressable(
                                                radius: WhisperRadius.capsule,
                                                label: MaterialLocalizations.of(
                                                  context,
                                                ).clearButtonTooltip,
                                                onTap: _controller.clear,
                                                child: SizedBox.square(
                                                  dimension: 36,
                                                  child: Center(
                                                    child: Icon(
                                                      Icons.cancel,
                                                      size: 18,
                                                      color: c.ink3,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                if (note != null)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      8,
                                      12,
                                      0,
                                    ),
                                    child: Text(
                                      note,
                                      style: TextStyle(
                                        fontSize: type.note,
                                        height: 1.35,
                                        color: problem != null ? c.bad : c.ink2,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// A continuous number: slider and value. In the panel on one line, on the
/// phone's page with a line of its own for the slider, so it can be wide.
class SettingsSliderRow extends StatelessWidget {
  const SettingsSliderRow({
    super.key,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    this.hint,
  });

  final String title, valueLabel;
  final String? hint;
  final double value, min, max;
  final int divisions;
  final ValueChanged<double> onChanged, onChangeEnd;

  static const _maxWidth = 240.0, _minWidth = 120.0, _valueWidth = 38.0;

  double _sliderWidth(BuildContext context, double row) {
    final painter = TextPainter(
      text: TextSpan(
        text: title,
        style: SettingsTextStyle.style.copyWith(
          fontSize: _type(context).body,
          height: 1.3,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final titleWidth = painter.width;
    painter.dispose();
    return (row - titleWidth - 10).clamp(_minWidth, _maxWidth);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final scope = SettingsScope.of(context);
    final type = _type(context);
    final label = Text(
      valueLabel,
      textAlign: TextAlign.end,
      maxLines: 1,
      style: TextStyle(
        fontSize: type.note,
        color: c.ink2,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final slider = Semantics(
      label: title,
      child: SliderTheme(
        data: whisperSliderTheme(context, touch: scope.touch),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
          semanticFormatterCallback: (_) => valueLabel,
        ),
      ),
    );
    if (scope.page) {
      return SettingsRowFrame(
        vertical: 8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: type.body,
                      height: 1.3,
                      color: c.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                label,
              ],
            ),
            const SizedBox(height: 4),
            _TallTarget(visible: 32, target: 48, child: slider),
            const SizedBox(height: 2),
            if (hint != null)
              Text(
                hint!,
                style: TextStyle(
                  fontSize: type.tiny,
                  height: 1.4,
                  color: c.ink2,
                ),
              ),
          ],
        ),
      );
    }
    return SettingsRowFrame(
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            Expanded(child: SettingsRowTitle(title: title)),
            const SizedBox(width: 10),
            SizedBox(
              width: _sliderWidth(context, box.maxWidth),
              child: Row(
                children: [
                  Expanded(child: slider),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: _valueWidth),
                    child: label,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Takes [visible] of the layout and answers to taps over [target]: a thin
/// control on a touch screen, whose neighbours should not move away from it.
/// Only for what sits inside a parent tall enough to reach it.
class _TallTarget extends SingleChildRenderObjectWidget {
  const _TallTarget({
    required this.visible,
    required this.target,
    required super.child,
  });

  final double visible, target;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTallTarget(visible, target);

  @override
  void updateRenderObject(BuildContext context, _RenderTallTarget object) {
    object
      ..visible = visible
      ..target = target
      ..markNeedsLayout();
  }
}

class _RenderTallTarget extends RenderShiftedBox {
  _RenderTallTarget(this.visible, this.target) : super(null);

  double visible, target;

  @override
  void performLayout() {
    child!.layout(
      BoxConstraints.tightFor(width: constraints.maxWidth, height: target),
    );
    size = constraints.constrain(Size(constraints.maxWidth, visible));
    (child!.parentData! as BoxParentData).offset = Offset(
      0,
      (visible - target) / 2,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hitTestChildren(result, position: position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

/// A row that comes and goes, for example with the switch above it. Its height
/// springs with it, so the rows below slide instead of jumping.
class SettingsCollapse extends StatelessWidget {
  const SettingsCollapse({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => SpringBuilder(
    value: visible ? 1 : 0,
    builder: (context, t, _) {
      final open = t.clamp(0.0, 1.0);
      if (!visible && open <= .001) return const SizedBox.shrink();
      return ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: open,
          child: Opacity(opacity: open, child: child),
        ),
      );
    },
  );
}

/// A path that does not fit loses its start: the end is the part that says
/// where the files go.
class SettingsPathText extends StatelessWidget {
  const SettingsPathText(this.path, {super.key});

  final String path;

  @override
  Widget build(BuildContext context) {
    final style = SettingsTextStyle.style.copyWith(
      fontSize: _type(context).note,
      color: context.wc.ink2,
    );
    return LayoutBuilder(
      builder: (context, box) {
        final direction = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        double widthOf(String text) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width;
        }

        var shown = path;
        if (widthOf(path) > box.maxWidth) {
          var low = 0, high = path.length;
          while (low < high) {
            final drop = (low + high) ~/ 2;
            if (widthOf('…${path.substring(drop)}') <= box.maxWidth) {
              high = drop;
            } else {
              low = drop + 1;
            }
          }
          shown = '…${path.substring(low)}';
        }
        return Text(shown, maxLines: 1, softWrap: false, style: style);
      },
    );
  }
}

/// A shortcut: a button that records the next combination pressed. Esc gives
/// up. Global shortcuts wait meanwhile, so pressing the current one records it
/// instead of taking a screenshot.
class SettingsShortcutButton extends StatefulWidget {
  const SettingsShortcutButton({
    super.key,
    required this.controller,
    required this.title,
    required this.onError,
  });

  final DesktopScreenshotController controller;
  final String title;
  final ValueChanged<String> onError;

  @override
  State<SettingsShortcutButton> createState() => _SettingsShortcutButtonState();
}

class _SettingsShortcutButtonState extends State<SettingsShortcutButton> {
  // Keys go through focus and not HardwareKeyboard's handlers, which the focus
  // system does not stop for: Esc would give up and close the panel as well.
  late final _focus = FocusNode(onKeyEvent: _onKey, skipTraversal: true);
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _end();
    });
  }

  void _begin() {
    if (_recording || widget.controller.configuring) return;
    widget.controller.shortcutsPaused = true;
    _focus.requestFocus();
    setState(() => _recording = true);
  }

  void _end() {
    if (!_recording) return;
    _recording = false;
    widget.controller.shortcutsPaused = false;
    _focus.unfocus();
    if (mounted) setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_recording) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) _end();
      return KeyEventResult.handled;
    }
    final candidate = ScreenshotShortcut.fromKeyEvent(event);
    if (candidate != null) {
      _end();
      unawaited(_apply(candidate));
    }
    return KeyEventResult.handled;
  }

  Future<void> _apply(ScreenshotShortcut candidate) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await widget.controller.configure(candidate, enabled: true);
    } on PlatformException catch (error) {
      widget.onError(
        error.code == 'shortcut-invalid'
            ? l10n.screenshotShortcutInvalid
            : l10n.screenshotShortcutFailed,
      );
    } catch (_) {
      widget.onError(l10n.screenshotShortcutFailed);
    }
  }

  @override
  void dispose() {
    _recording = false;
    widget.controller.shortcutsPaused = false;
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = _type(context);
    final touch = SettingsScope.of(context).touch;
    final l10n = AppLocalizations.of(context)!;
    final text = _recording
        ? l10n.shellSettingsPressShortcut
        : widget.controller.shortcutLabel;
    final button = Pressable(
      radius: WhisperRadius.s,
      label: '${widget.title}, $text',
      onTap: _recording ? _end : _begin,
      child: SettingsHighlight(
        base: _recording ? c.accent : c.fill,
        hover: _recording ? c.accent : c.fill2,
        radius: WhisperRadius.s,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: touch ? 34 : 28, minWidth: 76),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: type.note,
                  fontWeight: FontWeight.w500,
                  color: _recording ? c.onAccent : c.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Focus(focusNode: _focus, child: button);
  }
}

/// Status and one action for something a setting cannot just switch: a system
/// service, a desktop helper. The hint wraps under the title; the state never
/// does.
class SettingsServiceRow extends StatelessWidget {
  const SettingsServiceRow({
    super.key,
    required this.title,
    this.hint,
    required this.status,
    this.action,
    this.onAction,
    this.extra,
    this.onTap,
  });

  final String title, status;
  final String? hint;
  final String? action;
  final VoidCallback? onAction;

  /// One more control at the end of the row.
  final Widget? extra;

  /// The row itself, when there is nothing to press but something to read.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SettingsRow(
    title: title,
    subtitle: hint,
    minHeight: 58,
    onTap: onTap,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const SizedBox(width: 8),
        Flexible(child: SettingsValue(status)),
        if (action != null) ...[
          const SizedBox(width: 18),
          SettingsButton(label: action!, onTap: onAction),
        ],
        if (extra != null) ...[const SizedBox(width: 10), extra!],
      ],
    ),
  );
}

/// The coloured tile of a section.
class SettingsTile extends StatelessWidget {
  const SettingsTile({super.key, required this.glyph, required this.color});

  /// Null is this computer's laptop, drawn a little larger, as it has no
  /// outline to fill the tile with.
  final WhisperGlyph? glyph;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 22,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(WhisperRadius.xs),
      ),
      child: CustomPaint(
        foregroundPainter: const _GlassEdge(
          radius: WhisperRadius.xs,
          color: WhisperSettingsIcons.highlight,
        ),
        child: Center(
          child: glyph == null
              ? DeviceGlyph(
                  kind: DeviceKind.laptop,
                  color: context.wc.onAccent,
                  size: 16,
                )
              : WhisperIcon(
                  glyph!,
                  size: 13,
                  weight: 1.9,
                  color: context.wc.onAccent,
                ),
        ),
      ),
    ),
  );
}

/// A section in the panel's list. The selection fades across: the rows do not
/// move, so there is nothing for it to travel with.
class SettingsNavItem extends StatelessWidget {
  const SettingsNavItem({
    super.key,
    required this.title,
    required this.glyph,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final WhisperGlyph? glyph;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final type = _type(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Pressable(
        scale: 1,
        radius: WhisperRadius.m,
        selected: selected,
        onTap: onTap,
        child: SettingsHighlight(
          base: selected ? c.selected : null,
          hover: selected ? c.selected : c.fill,
          radius: WhisperRadius.m,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                children: [
                  SettingsTile(glyph: glyph, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: type.body,
                        height: 1.3,
                        fontWeight: selected
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: c.ink,
                      ),
                    ),
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

/// The panel's way out, top right.
class SettingsCloseButton extends StatelessWidget {
  const SettingsCloseButton({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return Tooltip(
      message: label,
      child: Pressable(
        radius: WhisperRadius.xs,
        label: label,
        onTap: onTap,
        child: SettingsHighlight(
          hover: c.fill,
          press: c.fill2,
          radius: WhisperRadius.xs,
          child: SizedBox.square(
            dimension: 28,
            child: Center(
              child: WhisperIcon(
                WhisperGlyph.x,
                size: 14,
                weight: 2,
                color: c.ink2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small label over a group on the phone's page.
class SettingsGroupLabel extends StatelessWidget {
  const SettingsGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: _type(context).note,
        fontWeight: FontWeight.w500,
        color: context.wc.ink2,
      ),
    ),
  );
}

/// The about panel: what this is, which version, where to find out more. A
/// sheet on a phone, a panel elsewhere.
class SettingsAboutSheet extends StatelessWidget {
  const SettingsAboutSheet({
    super.key,
    required this.icon,
    required this.name,
    required this.description,
    required this.version,
    required this.links,
    required this.doneLabel,
  });

  final Widget icon;
  final String name, description, version, doneLabel;

  /// Label and action, in order.
  final List<(String, VoidCallback)> links;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final scope = SettingsScope.of(context);
    final type = _type(context);
    final brightness = Theme.of(context).brightness;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: icon),
        const SizedBox(height: 8),
        Text(
          name,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: type.title,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: type.note, color: c.ink2),
        ),
        const SizedBox(height: 4),
        Text(
          version,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: type.note, color: c.ink2),
        ),
        const SizedBox(height: 14),
        DecoratedBox(
          decoration: ShapeDecoration(
            color: scope.page ? c.group : c.fill,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(WhisperRadius.m),
            ),
            shadows: scope.page ? WhisperShadow.e1(brightness) : null,
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(WhisperRadius.m),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, (label, open)) in links.indexed)
                  _RowLine(
                    show: scope.page && i > 0,
                    child: SettingsRow(
                      title: label,
                      onTap: open,
                      minHeight: scope.touch ? 48 : 40,
                      inset: _rowInsetPage,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: SettingsButton(
            filled: true,
            label: doneLabel,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
    if (scope.page) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: c.canvas,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(WhisperRadius.l),
            ),
          ),
          child: SettingsTextStyle(
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: SizedBox(
                        width: 36,
                        height: 5,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: c.fill2,
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    content,
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: c.raised,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(WhisperRadius.l),
              ),
              shadows: WhisperShadow.e3(brightness),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: SettingsTextStyle(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
