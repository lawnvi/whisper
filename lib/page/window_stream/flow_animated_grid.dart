import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'flow_space_theme.dart';

/// A grid whose items move to their new places when the list changes (a
/// search narrowing it, say): the ones that stay slide over, new ones grow
/// in one after another, and the ones that go shrink away where they were.
///
/// Lays out like [SliverGridDelegateWithMaxCrossAxisExtent]. Builds every
/// item, so it is for lists of a few hundred at most.
class FlowAnimatedGrid<T> extends StatefulWidget {
  const FlowAnimatedGrid({
    super.key,
    required this.items,
    required this.keyOf,
    required this.itemBuilder,
    required this.maxCrossAxisExtent,
    required this.mainAxisExtent,
    this.crossAxisSpacing = 0,
    this.mainAxisSpacing = 0,
  });

  final List<T> items;
  final Object Function(T item) keyOf;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final double maxCrossAxisExtent;
  final double mainAxisExtent;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  @override
  State<FlowAnimatedGrid<T>> createState() => _FlowAnimatedGridState<T>();
}

class _Leaving<T> {
  _Leaving(this.item, this.slot);

  final T item;
  final int slot;
}

class _FlowAnimatedGridState<T> extends State<FlowAnimatedGrid<T>> {
  static const _move = Duration(milliseconds: 460);
  static const _fade = Duration(milliseconds: 220);

  final _leaving = <Object, _Leaving<T>>{};

  /// Order in which this update's new items arrive, for the stagger.
  final _arrival = <Object, int>{};

  @override
  void initState() {
    super.initState();
    _noteArrivals(const {});
  }

  @override
  void didUpdateWidget(FlowAnimatedGrid<T> old) {
    super.didUpdateWidget(old);
    final present = {for (final item in widget.items) widget.keyOf(item)};
    final before = <Object>{};
    for (var slot = 0; slot < old.items.length; slot++) {
      final key = old.keyOf(old.items[slot]);
      before.add(key);
      if (!present.contains(key)) {
        _leaving.putIfAbsent(key, () => _Leaving(old.items[slot], slot));
      }
    }
    // Back before it finished leaving: it arrives again.
    _leaving.removeWhere((key, _) => present.contains(key));
    _noteArrivals(before);
  }

  void _noteArrivals(Set<Object> before) {
    _arrival.clear();
    var order = 0;
    for (final item in widget.items) {
      final key = widget.keyOf(item);
      if (!before.contains(key)) {
        _arrival[key] = order++;
      }
    }
  }

  void _gone(Object key) {
    if (mounted && _leaving.containsKey(key)) {
      setState(() => _leaving.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final still = flowReduceMotion(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = math.max(
          1,
          (width / (widget.maxCrossAxisExtent + widget.crossAxisSpacing))
              .ceil(),
        );
        final tileWidth =
            (width - widget.crossAxisSpacing * (columns - 1)) / columns;
        Offset place(int slot) => Offset(
          (slot % columns) * (tileWidth + widget.crossAxisSpacing),
          (slot ~/ columns) * (widget.mainAxisExtent + widget.mainAxisSpacing),
        );
        final rows = (widget.items.length / columns).ceil();
        final height = rows == 0
            ? 0.0
            : rows * widget.mainAxisExtent +
                  (rows - 1) * widget.mainAxisSpacing;
        final children = <Widget>[
          if (!still)
            for (final entry in _leaving.entries)
              Positioned(
                key: ValueKey(('leaving', entry.key)),
                left: place(entry.value.slot).dx,
                top: place(entry.value.slot).dy,
                width: tileWidth,
                height: widget.mainAxisExtent,
                child: IgnorePointer(
                  child: _Presence(
                    leaving: true,
                    duration: _fade,
                    onDone: () => _gone(entry.key),
                    child: widget.itemBuilder(context, entry.value.item),
                  ),
                ),
              ),
          for (var slot = 0; slot < widget.items.length; slot++)
            _slot(context, slot, place(slot), tileWidth, still),
        ];
        if (still && _leaving.isNotEmpty) {
          _leaving.clear();
        }
        return TweenAnimationBuilder<double>(
          tween: Tween(end: height),
          duration: still ? Duration.zero : _move,
          curve: const SpringCurve(),
          builder: (context, animated, child) => SizedBox(
            width: width,
            // Never cut off items still settling into the taller grid.
            height: math.max(animated, height),
            child: child,
          ),
          child: Stack(clipBehavior: Clip.none, children: children),
        );
      },
    );
  }

  Widget _slot(
    BuildContext context,
    int slot,
    Offset at,
    double tileWidth,
    bool still,
  ) {
    final item = widget.items[slot];
    final key = widget.keyOf(item);
    final arrival = _arrival[key];
    return AnimatedPositioned(
      key: ValueKey(key),
      duration: still ? Duration.zero : _move,
      curve: const SpringCurve(),
      left: at.dx,
      top: at.dy,
      width: tileWidth,
      height: widget.mainAxisExtent,
      child: _Presence(
        duration: still ? Duration.zero : _fade,
        // A short cascade, capped so a long list does not lag behind.
        delay: Duration(milliseconds: 18 * math.min(arrival ?? 0, 10)),
        child: widget.itemBuilder(context, item),
      ),
    );
  }
}

/// Grows in (or shrinks away) once, when first built.
class _Presence extends StatefulWidget {
  const _Presence({
    required this.child,
    required this.duration,
    this.leaving = false,
    this.delay = Duration.zero,
    this.onDone,
  });

  final Widget child;
  final Duration duration;
  final bool leaving;
  final Duration delay;
  final VoidCallback? onDone;

  @override
  State<_Presence> createState() => _PresenceState();
}

class _PresenceState extends State<_Presence>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.duration == Duration.zero ? 1 : 0,
  );
  late final Animation<double> _shown = () {
    final eased = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    return widget.leaving ? ReverseAnimation(eased) : eased;
  }();

  @override
  void initState() {
    super.initState();
    if (_controller.value < 1) {
      Future<void>.delayed(widget.delay, () async {
        if (!mounted) {
          return;
        }
        await _controller.forward().orCancel.catchError((_) {});
        widget.onDone?.call();
      });
    } else if (widget.onDone != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone!());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _shown,
      child: ScaleTransition(
        scale: Tween(begin: 0.82, end: 1.0).animate(_shown),
        child: widget.child,
      ),
    );
  }
}
