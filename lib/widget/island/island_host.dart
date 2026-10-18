import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../page/window_stream/flow_space_theme.dart';
import 'island_activity.dart';
import 'island_center.dart';
import 'island_sources.dart';
import 'island_views.dart';

/// The app's island on phones: one black capsule just under the status bar
/// (below the system's own island, never over it) showing what is going
/// on, with a small circle beside it for a second activity. Tap it to open
/// the card that lists everything with its actions; swipe it up to put it
/// away. Hidden in the background, where system notifications take over.
class IslandHost extends StatefulWidget {
  const IslandHost({
    super.key,
    required this.child,
    required this.navigatorKey,
    this.center,
  });

  final Widget child;

  /// Opens pages for the activities (a window sent here).
  final GlobalKey<NavigatorState> navigatorKey;

  /// The island to show; the app's own (with every source) by default.
  final IslandCenter? center;

  @override
  State<IslandHost> createState() => _IslandHostState();
}

class _IslandHostState extends State<IslandHost> with TickerProviderStateMixin {
  /// Lively (ζ ≈ 0.7), like the window and copy islands before it.
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 290,
    damping: 24,
  );
  static const _compactHeight = 36.0;
  static const _circle = 36.0;
  static const _gap = 6.0;

  /// Space the small island takes under the status bar: its gap above, its
  /// height, the same gap below. Pages move down by this while it shows,
  /// like the old double-height status bar, so nothing hides under it.
  static const _band = _gap + _compactHeight + _gap;

  late final IslandCenter _center;
  late final AppLifecycleListener _lifecycle;

  /// 0 gone, 1 the small island, 2 the card.
  late final AnimationController _stage = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _drag = AnimationController.unbounded(
    vsync: this,
  );

  /// 0 one island, 1 the circle beside it.
  late final AnimationController _split = AnimationController.unbounded(
    vsync: this,
  );

  /// The card's height, following what it holds.
  late final AnimationController _height = AnimationController.unbounded(
    vsync: this,
    value: 160,
  );
  double _measured = 0;

  /// How far pages are pushed down (springs between 0 and [_band]).
  late final AnimationController _push = AnimationController.unbounded(
    vsync: this,
  );
  double _pushTarget = 0;
  double _stageTarget = 0;
  double _splitTarget = 0;
  double _rawDrag = 0;
  double _leaveVelocity = 0;
  bool? _immersive;

  /// What was last shown, kept while the island leaves.
  _Frame? _frame;

  bool get _still => flowReduceMotion(context);

  @override
  void initState() {
    super.initState();
    _center = widget.center ?? IslandSetup.install(widget.navigatorKey);
    _center.haptics = _haptic;
    _center.addListener(_onCenter);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null) {
      _center.setForeground(_shows(state));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _onCenter();
      }
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _center.removeListener(_onCenter);
    if (_center.haptics == _haptic) {
      _center.haptics = null;
    }
    _stage.dispose();
    _drag.dispose();
    _split.dispose();
    _height.dispose();
    _push.dispose();
    super.dispose();
  }

  /// Shown while the app is on screen, also when something covers it for
  /// a moment (the notification shade): only the background hides it.
  static bool _shows(AppLifecycleState state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  void _onLifecycle(AppLifecycleState state) =>
      _center.setForeground(_shows(state));

  void _haptic(IslandHaptic haptic) {
    switch (haptic) {
      case IslandHaptic.selection:
        unawaited(HapticFeedback.selectionClick());
      case IslandHaptic.light:
        unawaited(HapticFeedback.lightImpact());
      case IslandHaptic.medium:
        unawaited(HapticFeedback.mediumImpact());
    }
  }

  // --------------------------------------------------------------- motion

  void _onCenter() {
    if (!mounted) {
      return;
    }
    final featured = _center.featured;
    if (featured != null) {
      _frame = _Frame(
        shown: featured,
        secondary: _center.secondary,
        others: _center.others,
      );
    }
    final stage = switch (_center.stage) {
      IslandStage.hidden => 0.0,
      IslandStage.compact => 1.0,
      IslandStage.expanded => 2.0,
    };
    if (stage != _stageTarget) {
      _stageTarget = stage;
      final velocity = stage == 0 ? _leaveVelocity : 0.0;
      _leaveVelocity = 0;
      unawaited(
        _springTo(_stage, stage, velocity: velocity).then((_) {
          if (mounted && _stageTarget == 0 && _stage.value < 0.05) {
            setState(() => _frame = null);
          }
        }),
      );
    }
    final split = _center.secondary != null ? 1.0 : 0.0;
    if (split != _splitTarget) {
      _splitTarget = split;
      unawaited(_springTo(_split, split));
    }
    _updatePush();
    setState(() {});
  }

  /// Pages make room while the island shows (small or open: the card lies
  /// over the page). Not over a page that hides the status bar, where the
  /// island floats over it.
  void _updatePush() {
    final shown = _center.stage != IslandStage.hidden;
    final target = shown && !_center.quiet && _immersive != true ? _band : 0.0;
    if (target == _pushTarget) {
      return;
    }
    _pushTarget = target;
    if (_still || _immersive == true) {
      _push.value = target;
      return;
    }
    unawaited(_springTo(_push, target));
  }

  Future<void> _springTo(
    AnimationController controller,
    double target, {
    double velocity = 0,
  }) async {
    if (!mounted) {
      return;
    }
    if (_still) {
      await controller
          .animateTo(
            target,
            duration: FlowSpaceTokens.quickDuration,
            curve: Curves.easeOut,
          )
          .orCancel
          .catchError((Object _) {});
      return;
    }
    await controller
        .animateWith(
          SpringSimulation(_spring, controller.value, target, velocity),
        )
        .orCancel
        .catchError((Object _) {});
  }

  void _onMeasured(double height) {
    if (!mounted || (height - _measured).abs() < 0.5) {
      return;
    }
    final first = _measured == 0;
    _measured = height;
    if (first || _stage.value < 1.05 || _still) {
      _height.value = height;
    } else {
      unawaited(_springTo(_height, height));
    }
  }

  // ------------------------------------------------------------- gestures

  void _onDragUpdate(DragUpdateDetails details) {
    _rawDrag += details.delta.dy;
    // Free upwards, heavy downwards.
    _drag.value = _rawDrag < 0
        ? _rawDrag * 0.6
        : 18 * (1 - math.exp(-_rawDrag / 60));
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_rawDrag < -20 || velocity < -400) {
      _leaveVelocity = velocity / 400;
      _center.swipeUp();
    } else if (_rawDrag > 16 || velocity > 400) {
      _center.pullDown();
    }
    _rawDrag = 0;
    unawaited(
      _drag
          .animateWith(
            SpringSimulation(_spring, _drag.value, 0, velocity / 1000),
          )
          .orCancel
          .catchError((Object _) {}),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // The status bar hidden: something fills the screen.
    final immersive = media.padding.top <= 0;
    if (immersive != _immersive) {
      _immersive = immersive;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _center.immersive = immersive;
          _updatePush();
        }
      });
    }
    final frame = _frame;
    return Stack(
      children: [
        // Always wrapped, so the page's state survives the island coming
        // and going.
        AnimatedBuilder(
          animation: _push,
          child: widget.child,
          builder: (context, child) {
            final push = immersive ? 0.0 : math.max(0.0, _push.value);
            return MediaQuery(
              data: media.copyWith(
                padding: media.padding.copyWith(top: media.padding.top + push),
                viewPadding: media.viewPadding.copyWith(
                  top: media.viewPadding.top + push,
                ),
              ),
              child: child!,
            );
          },
        ),
        if (frame != null)
          Positioned.fill(
            // Above the navigator: no page gives it text styles.
            child: Material(
              type: MaterialType.transparency,
              child: _buildIsland(context, media, frame),
            ),
          ),
      ],
    );
  }

  Widget _buildIsland(
    BuildContext context,
    MediaQueryData media,
    _Frame frame,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final left = media.padding.left;
    final area = media.size.width - left - media.padding.right;
    // Just under the status bar: Android keeps its clock, icons and its own
    // island there.
    final top = media.padding.top + 6;
    final openWidth = math.min(area - 16, 420.0);
    final secondary = frame.secondary;
    final compactWidth = math.min(
      240.0,
      area - 32 - (secondary == null ? 0 : _circle + _gap),
    );
    return AnimatedBuilder(
      animation: Listenable.merge([_stage, _drag, _split, _height]),
      builder: (context, _) {
        final s = math.max(0.0, _stage.value);
        final lift = (s - 1).clamp(0.0, 1.0);
        final split = (_split.value * (1 - lift)).clamp(0.0, 1.2);
        final openHeight = math.max(_compactHeight, _height.value);
        final double width;
        final double height;
        final double radius;
        if (s <= 1) {
          width = ui.lerpDouble(compactWidth * 0.5, compactWidth, s)!;
          height = ui.lerpDouble(_compactHeight * 0.75, _compactHeight, s)!;
          radius = height / 2;
        } else {
          final t = s - 1;
          width = ui.lerpDouble(compactWidth, openWidth, t)!;
          height = ui.lerpDouble(_compactHeight, openHeight, t)!;
          radius = ui.lerpDouble(_compactHeight / 2, 34, t.clamp(0.0, 1.0))!;
        }
        final shown = (s * 2.5).clamp(0.0, 1.0);
        final compactContent = (1 - (s - 1).abs() * 2.6).clamp(0.0, 1.0);
        final openContent = ((s - 1.55) / 0.45).clamp(0.0, 1.0);
        final splitWidth = (_circle + _gap) * split.clamp(0.0, 1.0);
        final islandLeft = left + (area - width - splitWidth) / 2;
        final y = top + _drag.value;
        final circleSize = _circle * (0.55 + 0.45 * split.clamp(0.0, 1.0));
        return Stack(
          children: [
            if (secondary != null && split > 0.01)
              Positioned(
                // Out from under the island's right end.
                left:
                    islandLeft +
                    width -
                    circleSize +
                    (circleSize + _gap) * split.clamp(0.0, 1.0),
                top: y + (_compactHeight - circleSize) / 2,
                width: circleSize,
                height: circleSize,
                child: Opacity(
                  opacity: (split * shown).clamp(0.0, 1.0),
                  child: _Circle(
                    activity: secondary,
                    onTap: _center.tapSecondary,
                  ),
                ),
              ),
            Positioned(
              top: y,
              left: islandLeft,
              width: width,
              height: math.max(height, 1),
              child: Opacity(
                opacity: shown,
                child: Listener(
                  onPointerDown: (_) => _center.hold(),
                  onPointerUp: (_) => _center.release(),
                  onPointerCancel: (_) => _center.release(),
                  child: Semantics(
                    container: true,
                    // Small: one button that says what is going on. Open:
                    // the card's own lines and buttons.
                    excludeSemantics: s < 1.5,
                    button: s < 1.5,
                    label: s < 1.5
                        ? frame.shown.presenter.describe(context)
                        : null,
                    hint: s < 1.5 ? l10n.islandHint : null,
                    onTap: s < 1.5 ? _center.tap : null,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _center.tap,
                      onVerticalDragUpdate: _onDragUpdate,
                      onVerticalDragEnd: _onDragEnd,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: Colors.black,
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(radius),
                            side: BorderSide(
                              color: IslandColors.hairline,
                              width: 0.5,
                            ),
                          ),
                          shadows: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: 0.14 + 0.14 * lift,
                              ),
                              blurRadius: 10 + 22 * lift,
                              offset: Offset(0, 3 + 9 * lift),
                            ),
                          ],
                        ),
                        child: ClipRSuperellipse(
                          borderRadius: BorderRadius.circular(radius),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              if (compactContent > 0)
                                Positioned.fill(
                                  child: Opacity(
                                    opacity: compactContent,
                                    child: MediaQuery.withClampedTextScaling(
                                      maxScaleFactor: 1.2,
                                      child: _switcher(
                                        frame.shown.id,
                                        frame.shown.presenter.compact(context),
                                      ),
                                    ),
                                  ),
                                ),
                              Positioned(
                                top: 0,
                                left: (width - openWidth) / 2,
                                width: openWidth,
                                child: Offstage(
                                  offstage: openContent <= 0,
                                  child: TickerMode(
                                    enabled: openContent > 0,
                                    child: _Measure(
                                      onHeight: _onMeasured,
                                      child: _materialize(
                                        openContent,
                                        MediaQuery.withClampedTextScaling(
                                          maxScaleFactor: 1.6,
                                          child: _Card(
                                            frame: frame,
                                            center: _center,
                                            l10n: l10n,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
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
          ],
        );
      },
    );
  }

  Widget _switcher(String id, Widget child) => AnimatedSwitcher(
    duration: FlowSpaceTokens.quickDuration,
    switchInCurve: Curves.easeOut,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween(begin: 0.92, end: 1.0).animate(animation),
        child: child,
      ),
    ),
    layoutBuilder: (current, previous) =>
        Stack(alignment: Alignment.center, children: [...previous, ?current]),
    child: KeyedSubtree(key: ValueKey(id), child: child),
  );

  /// Content comes into focus as the card opens: out of a blur, growing a
  /// touch, fading in.
  Widget _materialize(double t, Widget child) {
    final body = Opacity(
      opacity: t,
      child: Transform.scale(
        scale: 0.94 + 0.06 * t,
        alignment: Alignment.topCenter,
        child: child,
      ),
    );
    if (t >= 1 || t <= 0 || _still) {
      return body;
    }
    final sigma = (1 - t) * 9;
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: body,
    );
  }
}

class _Frame {
  const _Frame({
    required this.shown,
    required this.secondary,
    required this.others,
  });

  final IslandActivity shown;
  final IslandActivity? secondary;
  final List<IslandActivity> others;
}

/// The second activity, in a circle beside the island.
class _Circle extends StatelessWidget {
  const _Circle({required this.activity, required this.onTap});

  final IslandActivity activity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: activity.presenter.describe(context),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            shape: BoxShape.circle,
            border: Border.all(color: IslandColors.hairline, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest.shortestSide * 0.62;
              return Center(
                child: AnimatedSwitcher(
                  duration: FlowSpaceTokens.quickDuration,
                  child: KeyedSubtree(
                    key: ValueKey(activity.id),
                    child: activity.presenter.glyph(context, size),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The open card: the featured activity, then a line for each other one.
class _Card extends StatelessWidget {
  const _Card({required this.frame, required this.center, required this.l10n});

  static const _rows = 3;

  final _Frame frame;
  final IslandCenter center;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final others = frame.others;
    final shownOthers = others.take(_rows).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSwitcher(
          duration: FlowSpaceTokens.quickDuration,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topCenter,
            children: [
              for (final child in previous) Positioned.fill(child: child),
              ?current,
            ],
          ),
          child: KeyedSubtree(
            key: ValueKey(frame.shown.id),
            child: frame.shown.presenter.featured(context, center),
          ),
        ),
        if (shownOthers.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(height: 0.5, color: IslandColors.faint),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              4,
              14,
              others.length > _rows ? 0 : 8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final other in shownOthers)
                  KeyedSubtree(
                    key: ValueKey(other.id),
                    child: other.presenter.row(context, center),
                  ),
              ],
            ),
          ),
          if (others.length > _rows)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                l10n.islandMore(others.length - _rows),
                style: IslandText.rowStatus,
              ),
            ),
        ],
      ],
    );
  }
}

/// Tells its height after each layout.
class _Measure extends SingleChildRenderObjectWidget {
  const _Measure({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasure(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasure renderObject) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderMeasure extends RenderProxyBox {
  _RenderMeasure(this.onHeight);

  ValueChanged<double> onHeight;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height != _last) {
      _last = height;
      WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
    }
  }
}
