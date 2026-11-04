import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// docs/design/surfaces.md「窗口外壳」: the title and whatever the page keeps at
/// the right, in the band that moves the window. [rightInset] is the room the
/// window buttons need, and follows them on the same spring.
class ShareToolbar extends StatelessWidget {
  const ShareToolbar({
    super.key,
    required this.title,
    required this.rightInset,
    this.trailing,
    this.titleKey,
    this.controlsKey,
  });

  final String title;
  final double rightInset;
  final Widget? trailing;

  /// So the island can keep clear of them.
  final GlobalKey? titleKey, controlsKey;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    return ToolbarBand(
      child: SpringBuilder(
        value: rightInset,
        spring: WhisperSprings.smooth,
        builder: (context, right, child) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20 + right, 0),
          child: child,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .34,
                ),
                child: Text(
                  key: titleKey,
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: type.head,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
              ),
              const Spacer(),
              if (trailing != null)
                KeyedSubtree(key: controlsKey, child: trailing!),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line under the toolbar, there only once the content has scrolled. It lies
/// on the content: `.main.scrolled .tb{box-shadow}` takes no room.
class ShareToolbarLine extends StatelessWidget {
  const ShareToolbarLine({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: 0,
    height: 1 / MediaQuery.devicePixelRatioOf(context),
    child: IgnorePointer(
      child: SpringBuilder(
        value: visible ? 1 : 0,
        animateWhenReduced: true,
        child: ColoredBox(color: context.wc.sep),
        builder: (context, t, child) =>
            Opacity(opacity: t.clamp(0.0, 1.0), child: child),
      ),
    ),
  );
}

/// How every share page comes in: from 5 below, fading, with no direction.
class ShareEntrance extends StatelessWidget {
  const ShareEntrance({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SpringBuilder(
    from: 0,
    value: 1,
    animateWhenReduced: true,
    child: child,
    builder: (context, t, child) => Opacity(
      opacity: t.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(
          0,
          MediaQuery.disableAnimationsOf(context) ? 0 : 5 * (1 - t),
        ),
        child: child,
      ),
    ),
  );
}

/// Hovering eases in rather than jumping (`transition: background-color`).
/// [builder] gets how far along it is, 0 to 1.
class ShareHover extends StatefulWidget {
  const ShareHover({super.key, required this.builder, this.enabled = true});

  final Widget Function(BuildContext context, double hover) builder;
  final bool enabled;

  @override
  State<ShareHover> createState() => _ShareHoverState();
}

class _ShareHoverState extends State<ShareHover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: SpringBuilder(
      value: _hover && widget.enabled ? 1 : 0,
      spring: WhisperSprings.snappy,
      animateWhenReduced: true,
      builder: (context, t, _) => widget.builder(context, t.clamp(0.0, 1.0)),
    ),
  );
}

/// The prototype's line icons (`P` in docs/design/whisper-ui-language.html), in
/// the same 20 viewBox, for the places where a Material icon would look different.
enum ShareGlyph {
  check([
    [Offset(4, 10.5), Offset(8, 14.5), Offset(16, 5.5)],
  ]),
  updown([
    [Offset(6.5, 8), Offset(10, 4.5), Offset(13.5, 8)],
    [Offset(6.5, 12), Offset(10, 15.5), Offset(13.5, 12)],
  ]);

  const ShareGlyph(this.lines);

  final List<List<Offset>> lines;

  void paintInto(Canvas canvas, double size, Paint paint) {
    final scale = size / 20;
    final path = Path();
    for (final line in lines) {
      path.moveTo(line.first.dx * scale, line.first.dy * scale);
      for (final point in line.skip(1)) {
        path.lineTo(point.dx * scale, point.dy * scale);
      }
    }
    canvas.drawPath(path, paint);
  }
}

/// `ic(name, size, width)`.
class ShareGlyphIcon extends StatelessWidget {
  const ShareGlyphIcon(
    this.glyph, {
    super.key,
    required this.size,
    required this.stroke,
    required this.color,
  });

  final ShareGlyph glyph;
  final double size, stroke;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _GlyphPainter(glyph, size, stroke, color),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.size, this.stroke, this.color);

  final ShareGlyph glyph;
  final double size, stroke;
  final Color color;

  @override
  void paint(Canvas canvas, Size _) => glyph.paintInto(
    canvas,
    size,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * size / 20
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color,
  );

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph ||
      old.size != size ||
      old.stroke != stroke ||
      old.color != color;
}

/// A switch: 38 × 22, the knob slides on the snappy spring and widens while
/// held. The hit area is taller than it looks, 28 with a pointer.
class ShareSwitch extends StatefulWidget {
  const ShareSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;

  @override
  State<ShareSwitch> createState() => _ShareSwitchState();
}

class _ShareSwitchState extends State<ShareSwitch> {
  static const _width = 38.0, _height = 22.0, _knob = 18.0, _inset = 2.0;

  bool _down = false, _focused = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() => widget.onChanged?.call(!widget.value);

  void _set(bool down) {
    if (_enabled && down != _down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return Semantics(
      toggled: widget.value,
      enabled: _enabled,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: SystemMouseCursors.basic,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _set(true),
          onTapUp: (_) => _set(false),
          onTapCancel: () => _set(false),
          onTap: _enabled ? _toggle : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Opacity(
              opacity: _enabled ? 1 : .5,
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(WhisperRadius.capsule),
                  border: _focused
                      ? Border.all(
                          color: c.accent.withValues(alpha: .45),
                          width: 3,
                          strokeAlign: BorderSide.strokeAlignOutside,
                        )
                      : null,
                ),
                child: SpringBuilder(
                  value: widget.value ? 1 : 0,
                  spring: WhisperSprings.snappy,
                  builder: (context, on, _) => SpringBuilder(
                    value: _down ? 1 : 0,
                    spring: WhisperSprings.snappy,
                    builder: (context, held, _) {
                      final t = on.clamp(0.0, 1.0);
                      final knob = _knob + 4 * held.clamp(0.0, 1.0);
                      final travel = _width - _inset * 2 - knob;
                      return Container(
                        width: _width,
                        height: _height,
                        decoration: BoxDecoration(
                          color: Color.lerp(c.fill2, c.accent, t),
                          borderRadius: BorderRadius.circular(
                            WhisperRadius.capsule,
                          ),
                        ),
                        alignment: Alignment.centerLeft,
                        padding: EdgeInsets.only(left: _inset + travel * on),
                        child: Container(
                          width: knob,
                          height: _knob,
                          decoration: BoxDecoration(
                            color: c.onAccent,
                            borderRadius: BorderRadius.circular(
                              WhisperRadius.capsule,
                            ),
                            boxShadow: whisperKnobShadow,
                          ),
                        ),
                      );
                    },
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

/// A round check, 22: a 1.5 ring when off, solid accent with a white tick when
/// on. The target is 28 although the circle is 22.
class ShareCheck extends StatelessWidget {
  const ShareCheck({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final onChanged = this.onChanged;
    return Semantics(
      checked: value,
      child: Pressable(
        radius: WhisperRadius.capsule,
        selected: value,
        label: label,
        onTap: onChanged == null ? null : () => onChanged(!value),
        child: SizedBox.square(
          dimension: 28,
          child: Center(
            child: SpringBuilder(
              value: value ? 1 : 0,
              spring: WhisperSprings.snappy,
              builder: (context, t, _) => CustomPaint(
                size: const Size.square(22),
                painter: _CheckPainter(
                  t: t,
                  ring: c.ink3,
                  fill: c.accent,
                  tick: c.onAccent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter({
    required this.t,
    required this.ring,
    required this.fill,
    required this.tick,
  });

  final double t;
  final Color ring, fill, tick;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final on = t.clamp(0.0, 1.0);
    if (on < 1) {
      canvas.drawCircle(
        center,
        radius - .75,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = ring.withValues(alpha: ring.a * (1 - on)),
      );
    }
    if (on <= 0) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = fill.withValues(alpha: fill.a * on),
    );
    // ic('check', 13, 2.6): a 20 viewBox drawn at 13, centred.
    canvas.save();
    canvas.translate((size.width - 13) / 2, (size.height - 13) / 2);
    ShareGlyph.check.paintInto(
      canvas,
      13,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6 * 13 / 20
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = tick.withValues(alpha: tick.a * on),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.t != t || old.ring != ring || old.fill != fill || old.tick != tick;
}

enum ShareButtonKind { filled, tinted, plain }

/// DESIGN.md「组件」's button: a capsule in three kinds. Regular is 28 high with
/// `note` text, [large] is 36 with `body`.
class ShareButton extends StatelessWidget {
  const ShareButton({
    super.key,
    required this.label,
    required this.onTap,
    this.kind = ShareButtonKind.filled,
    this.large = false,
  });

  final String label;
  final VoidCallback? onTap;
  final ShareButtonKind kind;
  final bool large;

  /// One button in the app: this only names the kinds these pages use.
  @override
  Widget build(BuildContext context) => ShellButton(
    label: label,
    onTap: onTap,
    large: large,
    kind: switch (kind) {
      ShareButtonKind.filled => ShellButtonKind.primary,
      ShareButtonKind.tinted => ShellButtonKind.normal,
      ShareButtonKind.plain => ShellButtonKind.quiet,
    },
  );
}

/// An inset group: white rows on the canvas, with an [inset] line between them.
class ShareGroup extends StatelessWidget {
  const ShareGroup({super.key, required this.children, this.inset = 12});

  final List<Widget> children;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final hairline = 1 / MediaQuery.devicePixelRatioOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.group,
        borderRadius: BorderRadius.circular(WhisperRadius.m),
        boxShadow: WhisperShadow.e1(Theme.of(context).brightness),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WhisperRadius.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, child) in children.indexed)
              // `.row + .row::before`: the line lies on the row and adds no
              // height, so a row is exactly as tall as it says. Every row has
              // the same shape and carries its key out, so one that becomes
              // the first keeps its state and its springs.
              Stack(
                key: child.key == null ? null : ValueKey<Key>(child.key!),
                children: [
                  child,
                  Positioned(
                    left: inset,
                    right: 0,
                    top: 0,
                    height: hairline,
                    child: i == 0
                        ? const SizedBox.shrink()
                        : ColoredBox(color: c.sep),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// `.popb`: what is set, and a menu of what it can be.
class SharePopupButton<T> extends StatelessWidget {
  const SharePopupButton({
    super.key,
    required this.text,
    required this.label,
    required this.items,
    required this.onPicked,
  });

  final String text, label;
  final List<ShareMenuItem<T>> items;
  final ValueChanged<T> onPicked;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final picked = await showShareMenu<T>(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      items: items,
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    return ShareHover(
      builder: (context, hover) => Pressable(
        radius: WhisperRadius.s,
        label: label,
        onTap: () => unawaited(_open(context)),
        child: Container(
          height: 28,
          padding: const EdgeInsets.fromLTRB(11, 0, 8, 0),
          decoration: BoxDecoration(
            color: Color.lerp(c.fill, c.fill2, hover),
            borderRadius: BorderRadius.circular(WhisperRadius.s),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                maxLines: 1,
                style: TextStyle(
                  fontSize: const WhisperType(touch: false).note,
                  fontWeight: FontWeight.w500,
                  color: c.ink,
                ),
              ),
              const SizedBox(width: 6),
              ShareGlyphIcon(
                ShareGlyph.updown,
                size: 12,
                stroke: 2,
                color: c.ink2,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

@immutable
class ShareMenuItem<T> {
  const ShareMenuItem({
    required this.value,
    required this.label,
    this.checked = false,
  });

  final T value;
  final String label;
  final bool checked;
}

/// DESIGN.md「菜单」: panel glass, grown out of the button. Resolves to the value
/// picked, or null when dismissed by a click outside or Esc.
Future<T?> showShareMenu<T>(
  BuildContext context, {
  required Rect anchor,
  required List<ShareMenuItem<T>> items,
}) {
  final done = Completer<T?>();
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _ShareMenu<T>(
      anchor: anchor,
      items: items,
      onClosed: (value) {
        entry.remove();
        entry.dispose();
        if (!done.isCompleted) done.complete(value);
      },
    ),
  );
  overlay.insert(entry);
  return done.future;
}

class _ShareMenu<T> extends StatefulWidget {
  const _ShareMenu({
    required this.anchor,
    required this.items,
    required this.onClosed,
  });

  final Rect anchor;
  final List<ShareMenuItem<T>> items;
  final ValueChanged<T?> onClosed;

  @override
  State<_ShareMenu<T>> createState() => _ShareMenuState<T>();
}

class _ShareMenuState<T> extends State<_ShareMenu<T>> {
  static const _width = 210.0, _pad = 5.0, _row = 30.0, _gap = 6.0;

  final _scope = FocusScopeNode(debugLabel: 'share menu');
  final FocusNode? _previous = FocusManager.instance.primaryFocus;
  bool _closing = false;
  T? _picked;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    // Keys come here while it is open, wherever the focus was; `autofocus`
    // would do nothing, since what is underneath already has it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scope.requestFocus();
    });
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  void _close([T? value]) {
    if (_closing) return;
    setState(() {
      _closing = true;
      _picked = value;
    });
  }

  void _finish() {
    if (_gone) return;
    _gone = true;
    _previous?.requestFocus();
    widget.onClosed(_picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: false);
    final size = MediaQuery.sizeOf(context);
    final height = _pad * 2 + _row * widget.items.length;
    final below = widget.anchor.bottom + _gap + height <= size.height - 8;
    final top = below
        ? widget.anchor.bottom + _gap
        : math.max(8.0, widget.anchor.top - _gap - height);
    final left = (widget.anchor.right - _width)
        .clamp(8.0, math.max(8.0, size.width - _width - 8))
        .toDouble();
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(WhisperRadius.m),
    );
    return Material(
      type: MaterialType.transparency,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              FocusManager.instance.primaryFocus?.nextFocus(),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              FocusManager.instance.primaryFocus?.previousFocus(),
        },
        child: FocusScope(
          node: _scope,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                ),
              ),
              Positioned(
                left: left,
                top: top,
                width: _width,
                child: SpringBuilder(
                  from: 0,
                  value: _closing ? 0 : 1,
                  spring: WhisperSprings.smooth,
                  animateWhenReduced: true,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: shape,
                      shadows: WhisperShadow.e2(Theme.of(context).brightness),
                    ),
                    child: WhisperGlass(
                      kind: GlassKind.panel,
                      shape: shape,
                      child: DecoratedBox(
                        position: DecorationPosition.foreground,
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: WhisperShadow.highlight(
                                Theme.of(context).brightness,
                              ),
                              width: .5,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(_pad),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final item in widget.items)
                                _ShareMenuRow(
                                  label: item.label,
                                  checked: item.checked,
                                  onTap: () => _close(item.value),
                                  type: type,
                                  ink: c.ink,
                                  hover: c.accent,
                                  hoverInk: c.onAccent,
                                  height: _row,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  builder: (context, t, child) {
                    if (_closing && t <= .02) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _finish(),
                      );
                    }
                    final p = t.clamp(0.0, 1.0);
                    return Opacity(
                      opacity: p,
                      child: Transform.translate(
                        offset: Offset(0, (below ? -6 : 6) * (1 - p)),
                        child: Transform.scale(
                          scale: .92 + .08 * t,
                          alignment: below
                              ? Alignment.topRight
                              : Alignment.bottomRight,
                          child: child,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareMenuRow extends StatefulWidget {
  const _ShareMenuRow({
    required this.label,
    required this.checked,
    required this.onTap,
    required this.type,
    required this.ink,
    required this.hover,
    required this.hoverInk,
    required this.height,
  });

  final String label;
  final bool checked;
  final VoidCallback onTap;
  final WhisperType type;
  final Color ink, hover, hoverInk;
  final double height;

  @override
  State<_ShareMenuRow> createState() => _ShareMenuRowState();
}

class _ShareMenuRowState extends State<_ShareMenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ink = _hover ? widget.hoverInk : widget.ink;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Focus(
        onFocusChange: (focused) => setState(() => _hover = focused),
        child: Pressable(
          scale: 1,
          radius: WhisperRadius.xs,
          selected: widget.checked,
          onTap: widget.onTap,
          child: Container(
            height: widget.height,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              color: _hover ? widget.hover : widget.hover.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(WhisperRadius.xs),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: widget.type.body, color: ink),
                  ),
                ),
                if (widget.checked) ...[
                  const SizedBox(width: 9),
                  ShareGlyphIcon(
                    ShareGlyph.check,
                    size: 13,
                    stroke: 2,
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
