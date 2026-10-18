import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart'
    show DragStartBehavior, PointerDeviceKind, VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'flow_app_icon.dart';
import 'flow_recents_deck.dart';
import 'flow_space_theme.dart';
import 'flow_stack.dart';

/// Opens the window switcher over the page, the way a phone shows its
/// recent apps: the page blurs away and the stack the user tapped
/// ([origins]: each card's rect there) grows to fill the screen, laid out
/// on the same curve ([FlowStack]). Swipe across to browse, swipe a window
/// up to close it, tap one to open it. Closing, the windows go back into
/// the stack where it is then ([origins] is asked again as they go);
/// completes once they are there, for the stack to show again.
Future<void> showFlowSwitcher(
  BuildContext context, {
  required List<FlowTaskCard> cards,
  required double cardAspect,
  required Map<String, Rect> Function() origins,
  required void Function(FlowTaskCard card, Rect rect) onOpen,
  void Function(FlowTaskCard card)? onClose,
  String closeLabel = '',
  String rotateLabel = '',
  Future<ui.Image?>? backdrop,
}) {
  HapticFeedback.selectionClick();
  final closed = Completer<void>();
  final route = _SwitcherRoute(
    builder: (animation) => FlowSwitcher(
      animation: animation,
      cards: cards,
      cardAspect: cardAspect,
      origins: origins,
      onOpen: onOpen,
      onClose: onClose,
      closeLabel: closeLabel,
      rotateLabel: rotateLabel,
      backdrop: backdrop,
    ),
  );
  unawaited(Navigator.of(context).push(route));
  // Done as the windows land in the stack's places: the stack fades in
  // under them while they fade out.
  void watch() {
    final animation = route.animation;
    if (animation == null || closed.isCompleted) {
      return;
    }
    if (animation.status == AnimationStatus.dismissed ||
        (animation.status == AnimationStatus.reverse &&
            animation.value <= FlowSwitcher.landing)) {
      animation.removeListener(watch);
      closed.complete();
    }
  }

  route.animation?.addListener(watch);
  unawaited(
    route.completed.then((_) async {
      // Popped without an animation (removed): still give the stack back.
      await Future<void>.delayed(route.reverseTransitionDuration);
      if (!closed.isCompleted) {
        closed.complete();
      }
    }),
  );
  return closed.future;
}

class _SwitcherRoute extends PageRoute<void> {
  _SwitcherRoute({required this.builder});

  final Widget Function(Animation<double> animation) builder;

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 500);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 380);

  // Material: the text styles a page would give (no yellow underlines).
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Material(type: MaterialType.transparency, child: builder(animation));

  // The switcher animates itself (cards grow out of the stack).
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

class FlowSwitcher extends StatefulWidget {
  const FlowSwitcher({
    super.key,
    required this.animation,
    required this.cards,
    required this.cardAspect,
    required this.origins,
    required this.onOpen,
    this.onClose,
    this.closeLabel = '',
    this.rotateLabel = '',
    this.backdrop,
  });

  final Animation<double> animation;
  final List<FlowTaskCard> cards;

  /// The page behind, already blurred: drawn as is, so moving cards never
  /// make the whole screen blur again. Without it a live blur is used.
  final Future<ui.Image?>? backdrop;

  /// Width / height of a window as it shows here.
  final double cardAspect;

  /// Each card's rect in the stack it grows from and goes back into.
  final Map<String, Rect> Function() origins;
  final void Function(FlowTaskCard card, Rect rect) onOpen;
  final void Function(FlowTaskCard card)? onClose;
  final String closeLabel;
  final String rotateLabel;

  /// Closing, below this much of the way the windows are as good as in
  /// the stack: it shows again, and once it has, they fade out over it.
  static const double landing = 0.25;

  @override
  State<FlowSwitcher> createState() => _FlowSwitcherState();
}

/// Card size and where the front card sits, for a given screen and number
/// of windows ([count] may be fractional while one is going away).
class _Geometry {
  _Geometry(Size size, double aspect, EdgeInsets padding, double count)
    : screen = Offset.zero & size {
    final portrait = size.height > size.width;
    final room = Size(
      size.width - padding.horizontal,
      size.height - padding.vertical,
    );
    // A full stack runs from the deepest card, against the screen's left
    // edge, to the front card, a margin short of the right one: the cards
    // are as large as that allows (upright ones up to about four fifths of
    // the height), and the same size however many windows there are.
    final fullSpan =
        FlowStack.reachToCentre(FlowStack.deepestShown + 1.0) + 0.5;
    final widthFit =
        (size.width - padding.left - padding.right + _bleed) / fullSpan;
    final maxHeight =
        room.height * (aspect < 1 ? 0.9 : (portrait ? 0.6 : 0.66));
    cardWidth = math.min(widthFit, maxHeight * aspect);
    cardHeight = cardWidth / aspect;
    final dy = padding.top + room.height * 0.5;
    if (count <= 1) {
      center = Offset(padding.left + room.width * 0.5, dy);
      return;
    }
    final reach = FlowStack.reachToCentre(count) * cardWidth;
    // On a phone, or wide enough to fill the screen, the stack rests
    // against the left edge (newer cards peek in from the right). Held back
    // by the height on a tablet: the whole stack in the middle.
    final fills = cardWidth >= widthFit - 0.5 || size.shortestSide < 600;
    final left = fills
        ? padding.left - _bleed
        : padding.left +
              (room.width -
                      (FlowStack.reachToCentre(count) + 0.5) * cardWidth) /
                  2;
    center = Offset(left + reach, dy);
  }

  /// How far the deepest card tucks past the screen's edge.
  static const double _bleed = 2;

  final Rect screen;
  late final double cardWidth;
  late final double cardHeight;
  late final Offset center;

  Rect rectAt(double d) {
    final scale = FlowStack.scale(d);
    return Rect.fromCenter(
      center: Offset(center.dx + FlowStack.offset(d) * cardWidth, center.dy),
      width: cardWidth * scale,
      height: cardHeight * scale,
    );
  }
}

class _FlowSwitcherState extends State<FlowSwitcher>
    with TickerProviderStateMixin {
  /// iOS-like: quick, settling without a wobble (ζ ≈ 0.86).
  /// Settling after a swipe: unhurried and without a wobble (about half a
  /// second, ζ ≈ 0.95), carrying the finger's speed into it.
  static const _settle = SpringDescription(
    mass: 1,
    stiffness: 190,
    damping: 26,
  );

  /// A window thrown up carries on with the finger's speed.
  static const _throw = SpringDescription(mass: 1, stiffness: 160, damping: 24);

  late List<FlowTaskCard> _cards = List.of(widget.cards);

  /// Which window is in front, in places (fractional while moving).
  late final AnimationController _scroll = AnimationController.unbounded(
    vsync: this,
  );

  /// A window being swiped up (its key) and how far.
  String? _lifted;
  late final AnimationController _lift = AnimationController.unbounded(
    vsync: this,
  );

  /// After a window leaves, the rest close the gap.
  int? _removed;
  bool _removedNewer = false;
  late final AnimationController _collapse = AnimationController.unbounded(
    vsync: this,
  );

  /// The window tapped grows to fill the screen before it opens.
  String? _opening;
  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  // Pan bookkeeping: the card under the finger keeps pace with it.
  Offset? _panStart;
  bool? _horizontal;
  int _grabbed = 0;
  double _grabbedOffset = 0;

  /// How fast the row itself moves (places per second), which is what a
  /// release carries on with. (The finger's speed would not do: over the
  /// older windows, where they lie close, it turns into a huge one.)
  VelocityTracker? _rowSpeed;
  final _clock = Stopwatch()..start();

  /// The fastest a release carries the row on, in places per second.
  static const double _maxSpeed = 14;
  _Geometry? _geometry;
  final _rects = <String, Rect>{};
  bool _landscape = false;

  bool _isPhone(Size size) => size.shortestSide < 600;

  ui.Image? _backdrop;

  @override
  void initState() {
    super.initState();
    widget.backdrop?.then((image) {
      if (mounted) {
        setState(() => _backdrop = image);
      } else {
        image?.dispose();
      }
    });
  }

  @override
  void dispose() {
    if (_landscape) {
      // Back to how the app is held everywhere else.
      unawaited(
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
      );
    }
    _backdrop?.dispose();
    _scroll.dispose();
    _lift.dispose();
    _collapse.dispose();
    _zoom.dispose();
    super.dispose();
  }

  bool get _still => flowReduceMotion(context);

  int get _last => _cards.length - 1;

  // ------------------------------------------------------------- gestures

  void _onPanStart(DragStartDetails details) {
    final geometry = _geometry;
    if (_opening != null || _removed != null || geometry == null) {
      return;
    }
    _panStart = details.globalPosition;
    _rowSpeed = VelocityTracker.withKind(
      details.kind ?? PointerDeviceKind.touch,
    );
    _horizontal = null;
    _scroll.stop();
    // The card under the finger, else the one in front.
    final under = _cardAt(details.globalPosition);
    _grabbed = under ?? _scroll.value.round().clamp(0, _last);
    _grabbedOffset = _fingerOffsetFor(_scroll.value);
  }

  /// Where the finger stands, relative to the grabbed card's place (card
  /// widths), for the row to be at [scroll]; past an end, the pull that
  /// stretched it there.
  double _fingerOffsetFor(double scroll) {
    final end = scroll < 0 ? 0 : (scroll > _last ? _last : null);
    if (end == null) {
      return FlowStack.offset(scroll - _grabbed);
    }
    final give = (scroll - end) * FlowStack.slope(0);
    return FlowStack.offset((end - _grabbed).toDouble()) +
        FlowStack.pullFor(give);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final start = _panStart;
    final geometry = _geometry;
    if (start == null || geometry == null) {
      return;
    }
    final moved = details.globalPosition - start;
    if (_horizontal == null) {
      if (moved.distance < 6) {
        return;
      }
      _horizontal = moved.dx.abs() >= moved.dy.abs();
      if (_horizontal == false) {
        final under = _cardAt(start);
        _lifted = under == null ? null : _cards[under].key;
        _lift.value = 0;
      }
    }
    if (_horizontal == true) {
      // Where the grabbed card has to be for it to stay under the finger.
      final fingerOffset = _grabbedOffset + moved.dx / geometry.cardWidth;
      var value = _grabbed + FlowStack.placeOf(fingerOffset);
      // Past either end the whole row follows, harder the further, and
      // springs back on release. (Kept in places: one is 0.9 card widths
      // there, the row's spacing.)
      if (value < 0) {
        final beyond = fingerOffset - FlowStack.offset(-_grabbed.toDouble());
        value = FlowStack.rubber(beyond) / FlowStack.slope(0);
      } else if (value > _last) {
        final beyond =
            fingerOffset - FlowStack.offset(_last - _grabbed.toDouble());
        value = _last + FlowStack.rubber(beyond) / FlowStack.slope(0);
      }
      _scroll.value = value;
      _rowSpeed?.addPosition(
        details.sourceTimeStamp ?? _clock.elapsed,
        Offset(value, 0),
      );
    } else if (_lifted != null) {
      // Up freely, down only a little.
      _lift.value = moved.dy < 0 ? moved.dy : moved.dy * 0.2;
    }
  }

  void _onPanEnd(DragEndDetails details) {
    final geometry = _geometry;
    final horizontal = _horizontal;
    _panStart = null;
    _horizontal = null;
    if (geometry == null || horizontal == null) {
      return;
    }
    if (horizontal) {
      final velocity = (_rowSpeed?.getVelocity().pixelsPerSecond.dx ?? 0)
          .clamp(-_maxSpeed, _maxSpeed)
          .toDouble();
      // A flick carries on as a phone's switcher does: a quick one passes
      // several windows.
      final projected = _scroll.value + velocity * 0.22;
      final target = projected.roundToDouble().clamp(0, _last).toDouble();
      if (target != _scroll.value.roundToDouble()) {
        HapticFeedback.selectionClick();
      }
      _settleScroll(target, velocity);
      return;
    }
    final lifted = _lifted;
    if (lifted == null) {
      return;
    }
    final velocity = details.velocity.pixelsPerSecond.dy;
    final flung = velocity < -700 || _lift.value < -geometry.cardHeight * 0.4;
    if (flung && widget.onClose != null) {
      unawaited(_throwAway(lifted, velocity));
    } else {
      unawaited(
        _lift
            .animateWith(SpringSimulation(_settle, _lift.value, 0, velocity))
            .orCancel
            .then((_) {
              if (mounted) {
                setState(() => _lifted = null);
              }
            })
            .catchError((Object _) {}),
      );
    }
  }

  void _settleScroll(double target, double velocity) {
    if (_still) {
      _scroll.value = target;
      return;
    }
    unawaited(
      _scroll
          .animateWith(
            SpringSimulation(_settle, _scroll.value, target, velocity),
          )
          .orCancel
          .catchError((Object _) {}),
    );
  }

  /// The front-most card at [point] (newer cards lie on top).
  int? _cardAt(Offset point) {
    for (var index = 0; index < _cards.length; index++) {
      final rect = _rects[_cards[index].key];
      if (rect != null && rect.contains(point)) {
        return index;
      }
    }
    return null;
  }

  Future<void> _throwAway(String key, double velocity) async {
    final geometry = _geometry!;
    HapticFeedback.mediumImpact();
    if (_lifted != key) {
      setState(() => _lifted = key);
      _lift.value = 0;
    }
    final index = _cards.indexWhere((card) => card.key == key);
    if (index < 0) {
      return;
    }
    if (!_still) {
      final flight = _lift
          .animateWith(
            SpringSimulation(
              _throw,
              _lift.value,
              -geometry.screen.height,
              math.min(velocity, -1400),
            ),
          )
          .orCancel
          .catchError((Object _) {});
      // The rest close the gap at once, while it flies out (the last one
      // leaves before the page closes).
      if (_cards.length == 1) {
        await flight;
      }
    }
    if (!mounted) {
      return;
    }
    widget.onClose?.call(_cards[index]);
    if (_cards.length == 1) {
      Navigator.of(context).pop();
      return;
    }
    final focus = _scroll.value.round();
    setState(() {
      _removed = index;
      // A newer window gone (or the oldest, while in front): the focus
      // moves with the windows so the one in front stays in front.
      _removedNewer = index < focus || (index == focus && index == _last);
    });
    if (_still) {
      _collapse.value = 1;
    } else {
      await _collapse
          .animateWith(SpringSimulation(_settle, 0, 1, 0))
          .orCancel
          .catchError((Object _) {});
    }
    if (!mounted) {
      return;
    }
    _lift.stop();
    setState(() {
      final newFocus = _scroll.value - (_removedNewer ? 1 : 0);
      _cards = List.of(_cards)..removeAt(index);
      _scroll.value = newFocus.clamp(0, _last).toDouble();
      _removed = null;
      _removedNewer = false;
      _lifted = null;
      _lift.value = 0;
      _collapse.value = 0;
    });
  }

  Future<void> _open(FlowTaskCard card) async {
    if (_opening != null) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _opening = card.key);
    if (!_still) {
      await _zoom
          .animateTo(1, curve: Curves.easeInOutCubic)
          .orCancel
          .catchError((Object _) {});
    }
    if (!mounted) {
      return;
    }
    widget.onOpen(card, _geometry?.screen ?? Rect.zero);
    Navigator.of(context).pop();
  }

  void _toggleOrientation() {
    HapticFeedback.selectionClick();
    setState(() => _landscape = !_landscape);
    unawaited(
      SystemChrome.setPreferredOrientations(
        _landscape
            ? [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : [DeviceOrientation.portraitUp],
      ),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => _buildIn(context, constraints.biggest),
    );
  }

  Widget _buildIn(BuildContext context, Size size) {
    final media = MediaQuery.of(context);
    // Opening: a spring out of the stack; closing: back into it, quick at
    // first and settling gently into place.
    final grow = CurvedAnimation(
      parent: widget.animation,
      curve: const SpringCurve(),
      reverseCurve: Curves.easeIn,
    );
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.animation,
        _scroll,
        _lift,
        _collapse,
        _zoom,
      ]),
      builder: (context, _) {
        // The window being thrown away counts less and less as the rest
        // close up, so the stack slides along with them instead of jumping
        // once it is gone.
        final count =
            _cards.length - (_removed == null ? 0.0 : _collapse.value);
        final geometry = _geometry = _Geometry(
          size,
          widget.cardAspect,
          media.padding + const EdgeInsets.fromLTRB(0, 64, 16, 32),
          count,
        );
        // Closing, the windows go back into the stack the way they came
        // (one just opened stays, under the app taking over).
        final closing = widget.animation.status == AnimationStatus.reverse;
        final t = closing && _opening != null ? 1.0 : grow.value;
        final origins = widget.origins();
        final shown = widget.animation.value;
        final blur = (_still ? 1.0 : shown) * 20;
        _rects.clear();
        final children = <Widget>[
          // The page behind, blurred and dimmed; a tap there goes back.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: _backdrop != null
                  ? Opacity(
                      opacity: shown.clamp(0.0, 1.0),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          RawImage(image: _backdrop, fit: BoxFit.cover),
                          const ColoredBox(color: Color(0x4D000000)),
                        ],
                      ),
                    )
                  : widget.backdrop != null
                  // The blurred picture is a frame or two away: dim first.
                  ? ColoredBox(
                      color: Colors.black.withValues(alpha: 0.3 * shown),
                    )
                  : BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.3 * shown),
                      ),
                    ),
            ),
          ),
        ];
        // Oldest first, so newer windows lie on top.
        for (var index = _cards.length - 1; index >= 0; index--) {
          final child = _buildCard(geometry, index, _cards[index], t, origins);
          if (child != null) {
            children.add(child);
          }
        }
        if (_isPhone(size)) {
          children.add(_buildRotate(media, shown));
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          // From where the finger went down, not where the drag was
          // recognised: the card stays exactly under it.
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: Stack(children: children),
        );
      },
    );
  }

  Widget? _buildCard(
    _Geometry geometry,
    int index,
    FlowTaskCard card,
    double t,
    Map<String, Rect> origins,
  ) {
    final removed = _removed;
    // The window thrown away flies on from where it was; meanwhile the
    // windows past it move up by one to close the gap.
    final leaving = removed == index;
    final c = removed == null ? 0.0 : _collapse.value;
    final effective = removed != null && index > removed
        ? index - c
        : index.toDouble();
    final focus =
        _scroll.value - (removed != null && _removedNewer && !leaving ? c : 0);
    // Past an end the row slides as one; no card moves into the stack.
    final held = focus.clamp(0.0, _last.toDouble());
    final past =
        ((focus - held) * FlowStack.slope(0)).clamp(
          -FlowStack.maxBeyond,
          FlowStack.maxBeyond,
        ) *
        geometry.cardWidth;
    final d = held - effective;
    final target = geometry.rectAt(d).shift(Offset(past, 0));
    // Grown out of the card's place in the stack; cards the stack did not
    // show come out of its far end.
    final origin =
        origins[card.key] ??
        _farEnd(origins) ??
        Rect.fromCenter(
          center: geometry.center,
          width: 1,
          height: 1 / widget.cardAspect,
        );
    var rect = Rect.lerp(origin, target, t)!;
    if (!rect.overlaps(geometry.screen.inflate(geometry.cardWidth))) {
      return null;
    }
    var opacity = d < -4 ? (5 + d).clamp(0.0, 1.0) : 1.0;
    if (widget.animation.status == AnimationStatus.reverse &&
        _opening == null) {
      opacity *= (widget.animation.value / (FlowSwitcher.landing / 3)).clamp(
        0.0,
        1.0,
      );
    }
    if (!origins.containsKey(card.key)) {
      opacity *= t.clamp(0.0, 1.0);
    }
    var radius = 22.0;
    if (_lifted == card.key) {
      rect = rect.shift(Offset(0, _lift.value));
      opacity *= (1 + _lift.value / geometry.screen.height * 1.2).clamp(
        0.0,
        1.0,
      );
    }
    if (_opening != null) {
      if (_opening == card.key) {
        rect = Rect.lerp(rect, geometry.screen, _zoom.value)!;
        radius = 22 * (1 - _zoom.value);
      } else {
        opacity *= 1 - _zoom.value;
      }
    }
    _rects[card.key] = rect;
    // Every visible window has its name above it, as far as the newer one
    // on top leaves room.
    final over = index == 0
        ? null
        : geometry.rectAt(d + 1).shift(Offset(past, 0));
    final labelWidth = over == null
        ? rect.width
        : (over.left - rect.left).clamp(0.0, rect.width);
    final label =
        (math.min(1.0, labelWidth / 60) *
                (d < -3 ? (4 + d).clamp(0.0, 1.0) : 1.0) *
                t *
                (_opening == null ? 1 : 0))
            .clamp(0.0, 1.0);
    return Positioned.fromRect(
      rect: rect,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: RepaintBoundary(
          child: _SwitcherCard(
            card: card,
            radius: radius,
            shade: FlowStack.shade(d) * t.clamp(0.0, 1.0),
            label: label,
            labelWidth: labelWidth,
            closeLabel: widget.closeLabel,
            onTap: () => unawaited(_open(card)),
            onClose: widget.onClose == null
                ? null
                : () => unawaited(_throwAway(card.key, -1600)),
          ),
        ),
      ),
    );
  }

  /// The stack's last card shown, where hidden cards come from.
  Rect? _farEnd(Map<String, Rect> origins) {
    Rect? far;
    for (final rect in origins.values) {
      if (far == null || rect.left < far.left) {
        far = rect;
      }
    }
    return far;
  }

  Widget _buildRotate(MediaQueryData media, double shown) {
    return Positioned(
      top: media.padding.top + 12,
      right: 16,
      child: Opacity(
        opacity: shown.clamp(0.0, 1.0),
        child: Semantics(
          button: true,
          label: widget.rotateLabel,
          child: GestureDetector(
            onTap: _toggleOrientation,
            child: FlowGlass(
              radius: FlowSpaceTokens.capsuleRadius,
              tint: Colors.white.withValues(alpha: 0.18),
              child: SizedBox.square(
                dimension: 40,
                child: Icon(
                  _landscape
                      ? CupertinoIcons.device_phone_portrait
                      : CupertinoIcons.device_phone_landscape,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitcherCard extends StatelessWidget {
  const _SwitcherCard({
    required this.card,
    required this.radius,
    required this.shade,
    required this.label,
    required this.labelWidth,
    required this.closeLabel,
    required this.onTap,
    this.onClose,
  });

  final FlowTaskCard card;
  final double radius;
  final double shade;

  /// How much the name above shows (0–1).
  final double label;

  /// The part of the card not under the newer one on top: the name stays
  /// within it, so names never run over each other.
  final double labelWidth;
  final String closeLabel;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    return Semantics(
      button: true,
      label: card.title,
      customSemanticsActions: {
        if (onClose != null && closeLabel.isNotEmpty)
          CustomSemanticsAction(label: closeLabel): onClose!,
      },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 2,
            width: math.max(0, labelWidth - 6),
            top: -38,
            height: 30,
            // Clipped to the room left, the name never pushes past it.
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: math.max(labelWidth - 6, 32),
                child: Opacity(
                  opacity: label,
                  child: Row(
                    children: [
                      FlowAppIcon(
                        label: card.title,
                        icon: card.icon,
                        hue: card.hue,
                        size: 24,
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          // The app's name, as a phone's recents show it.
                          card.title.split(' — ').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(color: Color(0x66000000), blurRadius: 8),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              onTap: onTap,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: shape,
                  color: const Color(0xFF1C1C1E),
                  shadows: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 18,
                      offset: Offset(-2, 6),
                    ),
                  ],
                ),
                child: ClipPath(
                  clipper: ShapeBorderClipper(shape: shape),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (card.snapshot != null)
                        FlowCardPicture(snapshot: card.snapshot!)
                      else
                        ColoredBox(
                          color: card.hue.withValues(alpha: 0.5),
                          child: Center(
                            child: FlowAppIcon(
                              label: card.title,
                              icon: card.icon,
                              hue: card.hue,
                              size: 56,
                              onColor: true,
                            ),
                          ),
                        ),
                      if (shade > 0)
                        ColoredBox(
                          color: Colors.black.withValues(alpha: shade),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// [boundary]'s picture, small and blurred once, for the switcher's
/// background.
Future<ui.Image?> blurredSnapshot(RenderRepaintBoundary boundary) async {
  try {
    final image = await boundary.toImage(pixelRatio: 0.3);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(
      image,
      Offset.zero,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 7,
          sigmaY: 7,
          tileMode: TileMode.clamp,
        ),
    );
    final blurred = await recorder.endRecording().toImage(
      image.width,
      image.height,
    );
    image.dispose();
    return blurred;
  } catch (_) {
    return null;
  }
}
