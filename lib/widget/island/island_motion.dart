import 'dart:async';
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// DESIGN.md `island-motion`: a piece of the island part of the way in or
/// out. Always the same widgets around [child], so what is inside keeps its
/// state when the veil lifts.
Widget islandVeil(
  Widget child, {
  required double shown,
  required double scale,
  double blur = 0,
  Alignment alignment = Alignment.topCenter,
}) => Opacity(
  opacity: shown.clamp(0.0, 1.0),
  child: Transform.scale(
    scale: scale,
    alignment: alignment,
    child: ImageFiltered(
      enabled: blur > .05,
      imageFilter: ImageFilter.blur(
        sigmaX: blur,
        sigmaY: blur,
        tileMode: TileMode.decal,
      ),
      child: child,
    ),
  ),
);

/// Content of the island that turns into other content when [identity]
/// changes: the old blurs away going the way the island goes, the new comes
/// out of a blur. Only the new one is laid out; the old is drawn over it at
/// the size it had, lined up by [alignment].
class IslandMorph extends StatefulWidget {
  const IslandMorph({
    super.key,
    required this.identity,
    required this.child,
    this.spring,
    this.from = WhisperIslandMotion.near,
    this.to,
    this.blur = WhisperIslandMotion.blur,
    this.alignment = Alignment.topCenter,
  });

  final Object identity;
  final Widget child;
  final SpringDescription? spring;

  /// The scale the new content comes from, and the one the old goes to (by
  /// default the other way, so both seem to go along with the island).
  final double from;
  final double? to;
  final double blur;
  final Alignment alignment;

  @override
  State<IslandMorph> createState() => _IslandMorphState();
}

class _IslandMorphState extends State<IslandMorph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  static const _newKey = ValueKey('new'), _oldKey = ValueKey('old');

  Widget? _old;
  Size? _oldSize;
  Size? _size;
  late double _oldTo, _from;

  @override
  void didUpdateWidget(IslandMorph old) {
    super.didUpdateWidget(old);
    if (old.identity == widget.identity) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _old = null;
      _c.value = 1;
      return;
    }
    // Not laid out yet: nothing to turn from.
    if (_size == null) return;
    _old = old.child;
    _oldSize = _size;
    _from = widget.from;
    _oldTo = widget.to ?? 1 / widget.from;
    _c.value = 0;
    _c
        .animateWith(
          SpringSimulation(widget.spring ?? WhisperSprings.smooth, 0, 1, 0),
        )
        .whenCompleteOrCancel(() {
          if (mounted && _c.value >= .999) setState(() => _old = null);
        });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = IslandSizeReport(
      onSize: (size) => _size = size,
      child: widget.child,
    );
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final old = _old;
        final p = _c.value.clamp(0.0, 1.0);
        final coming = old == null
            ? 1.0
            : ((p - WhisperIslandMotion.inFrom) /
                      (1 - WhisperIslandMotion.inFrom))
                  .clamp(0.0, 1.0);
        final going = (p / WhisperIslandMotion.outBy).clamp(0.0, 1.0);
        final oldSize = _oldSize;
        return Stack(
          alignment: widget.alignment,
          clipBehavior: Clip.none,
          children: [
            KeyedSubtree(
              key: _newKey,
              child: islandVeil(
                current,
                shown: coming,
                scale: old == null ? 1 : lerpDouble(_from, 1, coming)!,
                blur: old == null ? 0 : (1 - coming) * widget.blur,
                alignment: widget.alignment,
              ),
            ),
            if (old != null && going < 1)
              Positioned(
                key: _oldKey,
                width: oldSize?.width,
                height: oldSize?.height,
                child: IgnorePointer(
                  child: islandVeil(
                    old,
                    shown: 1 - going,
                    scale: lerpDouble(1, _oldTo, going)!,
                    blur: going * widget.blur,
                    alignment: widget.alignment,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Says how big [child] is laid out, every time that changes, after the
/// frame: for what follows its size with a spring.
class IslandSizeReport extends SingleChildRenderObjectWidget {
  const IslandSizeReport({super.key, required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReport(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeReport renderObject,
  ) {
    renderObject.onSize = onSize;
  }
}

class _RenderSizeReport extends RenderProxyBox {
  _RenderSizeReport(this.onSize);

  ValueChanged<Size> onSize;
  Size? _told;

  @override
  void performLayout() {
    super.performLayout();
    final now = size;
    if (now == _told) return;
    _told = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached && _told == now) onSize(now);
    });
  }
}

/// Text whose numbers roll when they change, digit by digit, up when they
/// grow and down when they shrink. When the words around them change, the
/// whole line turns into the new one instead.
class IslandFigures extends StatelessWidget {
  const IslandFigures(
    this.text, {
    super.key,
    required this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow overflow;

  static final _runs = RegExp(r'\d+|\D+');

  @override
  Widget build(BuildContext context) {
    final runs = [for (final m in _runs.allMatches(text)) m.group(0)!];
    bool digits(String run) {
      final c = run.codeUnitAt(0);
      return c >= 0x30 && c <= 0x39;
    }

    final words = [
      for (final run in runs) digits(run) ? '#' : run,
    ].join('\u0000');
    return IslandMorph(
      identity: words,
      from: 1,
      to: 1,
      alignment: AlignmentDirectional.topStart.resolve(
        Directionality.of(context),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            for (final (i, run) in runs.indexed)
              if (digits(run))
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: _Number(key: ValueKey(i), value: run, style: style),
                )
              else
                TextSpan(text: run),
          ],
        ),
        style: style,
        maxLines: maxLines,
        overflow: overflow,
      ),
    );
  }
}

class _Number extends StatefulWidget {
  const _Number({super.key, required this.value, required this.style});

  final String value;
  final TextStyle style;

  @override
  State<_Number> createState() => _NumberState();
}

class _NumberState extends State<_Number> {
  int _way = 1;

  /// Digits it has had: one more than that comes in like a change.
  int _had = 0;

  @override
  void didUpdateWidget(_Number old) {
    super.didUpdateWidget(old);
    final was = int.tryParse(old.value), now = int.tryParse(widget.value);
    if (was != null && now != null && was != now) _way = now > was ? 1 : -1;
    _had = old.value.length;
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    // Counted from the right, so a number that grows a digit keeps the rest.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < value.length; i++)
          _Digit(
            key: ValueKey(value.length - i),
            digit: value[i],
            way: _way,
            style: widget.style,
            enter: _had > 0 && value.length - i > _had,
          ),
      ],
    );
  }
}

class _Digit extends StatefulWidget {
  const _Digit({
    super.key,
    required this.digit,
    required this.way,
    required this.style,
    this.enter = false,
  });

  final String digit;
  final int way;
  final TextStyle style;

  /// New in the number: it rolls in from nothing.
  final bool enter;

  @override
  State<_Digit> createState() => _DigitState();
}

class _DigitState extends State<_Digit> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  String? _was;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.enter) _roll('');
  }

  @override
  void didUpdateWidget(_Digit old) {
    super.didUpdateWidget(old);
    if (old.digit != widget.digit) _roll(old.digit);
  }

  void _roll(String from) {
    if (MediaQuery.disableAnimationsOf(context)) return;
    _was = from;
    _c.value = 0;
    _c
        .animateWith(SpringSimulation(WhisperSprings.snappy, 0, 1, 0))
        .whenCompleteOrCancel(() {
          if (mounted && _c.value >= .999) setState(() => _was = null);
        });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final line = (style.fontSize ?? 14) * (style.height ?? 1.2);
    final rise = line * WhisperIslandMotion.figureRise;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final p = _c.value;
        final shown = p.clamp(0.0, 1.0);
        final was = _was;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Transform.translate(
              key: const ValueKey('now'),
              offset: Offset(0, was == null ? 0 : widget.way * (1 - p) * rise),
              child: islandVeil(
                Text(widget.digit, style: style),
                shown: was == null ? 1 : shown,
                scale: 1,
                blur: was == null
                    ? 0
                    : (1 - shown) * WhisperIslandMotion.figureBlur,
              ),
            ),
            if (was != null)
              Positioned(
                key: const ValueKey('was'),
                left: 0,
                top: 0,
                child: Transform.translate(
                  offset: Offset(0, -widget.way * p * rise),
                  child: islandVeil(
                    Text(was, style: style),
                    shown: 1 - shown,
                    scale: 1,
                    blur: shown * WhisperIslandMotion.figureBlur,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Rows of the open island that come and go: a new one comes out of a blur
/// under the others while the island grows to make room for it; one that is
/// over fades and blurs away before the island closes up after it. The order
/// is [children]'s when the island opens. Each child needs a key.
class IslandRows extends StatefulWidget {
  const IslandRows({super.key, required this.children});

  final List<Widget> children;

  @override
  State<IslandRows> createState() => _IslandRowsState();
}

class _RowEntry {
  _RowEntry(this.child, {required this.coming});

  Widget child;
  bool coming;
  bool going = false;
  Key get key => child.key!;
}

class _IslandRowsState extends State<IslandRows> {
  late final List<_RowEntry> _rows = [
    for (final child in widget.children) _RowEntry(child, coming: false),
  ];

  @override
  void didUpdateWidget(IslandRows old) {
    super.didUpdateWidget(old);
    final keys = {for (final child in widget.children) child.key};
    for (final row in _rows) {
      if (!keys.contains(row.key)) row.going = true;
    }
    // The rows there stay where they are and a new one comes in under them:
    // nothing on the island is pushed out of its place.
    for (final child in widget.children) {
      final i = _rows.indexWhere((row) => row.key == child.key);
      if (i >= 0) {
        _rows[i]
          ..child = child
          ..going = false;
      } else {
        _rows.add(_RowEntry(child, coming: true));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final row in _rows)
        _RowMotion(
          key: row.key,
          coming: row.coming,
          going: row.going,
          onGone: () {
            if (mounted) setState(() => _rows.remove(row));
          },
          child: row.child,
        ),
    ],
  );
}

class _RowMotion extends StatefulWidget {
  const _RowMotion({
    super.key,
    required this.coming,
    required this.going,
    required this.onGone,
    required this.child,
  });

  final bool coming, going;
  final VoidCallback onGone;
  final Widget child;

  @override
  State<_RowMotion> createState() => _RowMotionState();
}

class _RowMotionState extends State<_RowMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: widget.coming ? 0 : 1,
  )..addListener(_tick);

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.coming) _go(1, WhisperSprings.smooth);
  }

  @override
  void didUpdateWidget(_RowMotion old) {
    super.didUpdateWidget(old);
    if (widget.going != old.going) {
      widget.going
          ? _go(0, WhisperSprings.snappy)
          : _go(1, WhisperSprings.smooth);
    }
  }

  void _go(double to, SpringDescription spring) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.value = to;
      return;
    }
    unawaited(
      _c.animateWith(SpringSimulation(spring, _c.value, to, _c.velocity)),
    );
  }

  /// Its room all but gone, it leaves the rows: the spring's last stretch
  /// would show nothing.
  void _tick() {
    if (widget.going && _c.value <= .01) _done();
  }

  bool _gone = false;

  /// After the frame: it may be noticed while the rows are being built.
  void _done() {
    if (_gone) return;
    _gone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.going) {
        widget.onGone();
      } else {
        _gone = false;
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: widget.going,
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final p = _c.value.clamp(0.0, 1.0);
        // Going, it is out of sight first, then its room closes up, so the
        // rows under it move up instead of jumping.
        final going = widget.going;
        final shown = going
            ? ((p - WhisperIslandMotion.contentFrom) /
                      (1 - WhisperIslandMotion.contentFrom))
                  .clamp(0.0, 1.0)
            : p;
        final room = going
            ? (p / WhisperIslandMotion.contentFrom).clamp(0.0, 1.0)
            : 1.0;
        return ClipRect(
          clipBehavior: room < 1 ? Clip.hardEdge : Clip.none,
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: room,
            child: islandVeil(
              child!,
              shown: shown,
              scale: lerpDouble(WhisperIslandMotion.near, 1, p)!,
              blur: (1 - shown) * WhisperIslandMotion.blur,
            ),
          ),
        );
      },
      child: widget.child,
    ),
  );
}

/// What leads a line on the island (a ring, a tick, a warning). Turning into
/// another, the old one shrinks away and the new one pops out. Tell them apart
/// by key when they are the same kind of widget.
class IslandGlyph extends StatelessWidget {
  const IslandGlyph({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => IslandMorph(
    identity: child.key ?? child.runtimeType,
    spring: WhisperSprings.expressive,
    from: WhisperIslandMotion.pop,
    to: WhisperIslandMotion.pop,
    blur: WhisperIslandMotion.figureBlur,
    alignment: Alignment.center,
    child: child,
  );
}
