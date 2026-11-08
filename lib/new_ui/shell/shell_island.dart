import 'dart:ui' show lerpDouble;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';
import 'package:whisper/widget/island/island_motion.dart';
import 'package:whisper/widget/island/island_views.dart';

/// Where the island goes on a desktop window (the prototype's `placeIsland`).
/// Pure, so the rules can be tested.
///
/// It is the most important thing in the window, so it is in the window's middle
/// and nothing moves it sideways: over the toolbar, 9 from the top, or below the
/// toolbar, 58 from the top, when it would cover the title or the controls.
/// Opened, it stays up there and only goes down to clear the window buttons.
Offset shellIslandOrigin({
  required double width,
  required double windowWidth,
  required double controlsLeft,
  required double titleRight,
  required bool expanded,
  required double buttonsLeft,
  required double buttonsBottom,
}) {
  const top = 9.0, below = 58.0, clearance = 10.0, buttonGap = 6.0;
  final left = (windowWidth - width) / 2;
  final right = left + width;
  if (expanded) {
    return Offset(
      left,
      right > buttonsLeft - clearance ? buttonsBottom + buttonGap : top,
    );
  }
  final clear =
      right <= math.min(controlsLeft, buttonsLeft) - clearance &&
      left >= titleRight + clearance;
  return Offset(left, clear ? top : below);
}

/// What the island shows of an activity: the prototype's `moments()`.
class IslandMoment {
  const IslandMoment({
    required this.leading,
    required this.title,
    this.detail = '',
    this.value,
    this.answers = const [],
    this.onStop,
    this.stopLabel = '',
    this.art,
    this.code,
  });

  final Widget leading;
  final String title, detail;

  /// What an open question has at its top: who asks, or the warning.
  final Widget? art;

  /// The digits two devices compare.
  final String? code;

  /// A number beside the title on the small island: 59%.
  final String? value;
  final List<IslandAnswer> answers;
  final VoidCallback? onStop;
  final String stopLabel;
}

/// [IslandMoment] as the touch island draws it, for presenters that also have
/// to work on a phone's island, in its small capsule and open card.
mixin MomentViews on IslandPresenter implements MomentPresenter {
  @override
  Widget compact(BuildContext context) {
    final m = moment(context);
    return IslandCompactLine(
      leading: IslandGlyph(child: m.leading),
      title: m.title,
      trailing: m.value == null
          ? null
          : IslandFigures(
              m.value!,
              style: IslandText.compactFigure(IslandColors.dim),
            ),
    );
  }

  @override
  Widget featured(BuildContext context, IslandControls controls) {
    final m = moment(context);
    if (m.answers.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(9),
        child: IslandAskCard(moment: m, touch: true),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IslandHead(
            leading: IslandTile(tint: IslandColors.blue, child: m.leading),
            title: m.title,
            subtitle: m.detail,
            trailing: [
              if (m.onStop case final stop?)
                _MomentAction(label: m.stopLabel, onTap: stop),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget row(BuildContext context, IslandControls controls) {
    final m = moment(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          IslandGlyph(child: m.leading),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              m.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: IslandText.compactTitle,
            ),
          ),
          if (m.value case final value?) ...[
            const SizedBox(width: 8),
            IslandFigures(
              value,
              style: IslandText.compactFigure(IslandColors.dim),
            ),
          ],
        ],
      ),
    );
  }
}

class _MomentAction extends StatelessWidget {
  const _MomentAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(
          widthFactor: 1,
          child: Text(
            label,
            style: IslandText.compactTitle.copyWith(color: IslandColors.blue),
          ),
        ),
      ),
    ),
  );
}

/// docs/design/surfaces.md「灵动岛」: a question, centred from top to bottom. Who
/// asks, what they want, the digits to compare when there are any, the answers.
class IslandAskCard extends StatelessWidget {
  const IslandAskCard({super.key, required this.moment, this.touch = false});

  final IslandMoment moment;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final type = WhisperType(touch: touch);
    final m = moment;
    const faint = Radix.whiteA3;
    final height = touch ? 44.0 : 34.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(7, 12, 7, 7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A picture when a device is asking, the warning when it is one, and
          // nothing rather than a question mark that says nothing.
          if (m.art case final top?) ...[
            Center(child: top),
            const SizedBox(height: 10),
          ],
          Text(
            m.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: type.head,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          if (m.detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              m.detail,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: type.note,
                height: 1.4,
                color: Radix.whiteA8,
              ),
            ),
          ],
          if (m.code case final code?) ...[
            const SizedBox(height: 12),
            Text(
              code,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: WhisperMono.family,
                fontFamilyFallback: WhisperMono.fallback,
                fontSize: WhisperSizes.pairCode,
                height: 1.2,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              for (final (i, answer) in m.answers.indexed) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: Pressable(
                    onTap: answer.onTap,
                    radius: WhisperRadius.capsule,
                    label: answer.label,
                    child: Container(
                      height: height,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: answer.primary ? Colors.white : faint,
                        borderRadius: BorderRadius.circular(height / 2),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          answer.label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: type.note,
                            fontWeight: FontWeight.w600,
                            color: answer.primary ? Colors.black : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A presenter that can say what it shows as one [IslandMoment]. Others are laid
/// out by their own `compact` and `featured`.
abstract interface class MomentPresenter {
  IslandMoment moment(BuildContext context);
}

/// docs/design/surfaces.md「灵动岛」: one black capsule, the same in both themes.
class ShellIsland extends StatefulWidget {
  const ShellIsland({
    super.key,
    required this.center,
    required this.windowWidth,
    required this.controlsLeft,
    required this.titleRight,
    required this.buttonsLeft,
    required this.buttonsBottom,
  });

  final IslandCenter center;
  final double windowWidth,
      controlsLeft,
      titleRight,
      buttonsLeft,
      buttonsBottom;

  @override
  State<ShellIsland> createState() => _ShellIslandState();
}

class _ShellIslandState extends State<ShellIsland> implements IslandControls {
  static const _openWidth = 372.0, _compactHeight = 34.0, _compactMax = 260.0;

  Size _measured = const Size(120, _compactHeight);

  /// Which way the island last went: growing (coming, opening, a row more)
  /// it is lively; going small or away it has nothing left to say.
  bool _growing = true;
  bool _wasShown = false, _wasExpanded = false;

  /// What it last said, for going away with it.
  IslandActivity? _last;

  SpringDescription get _spring =>
      _growing ? WhisperSprings.expressive : WhisperSprings.snappy;

  @override
  void initState() {
    super.initState();
    widget.center.addListener(_changed);
    widget.center.setForeground(true);
  }

  @override
  void didUpdateWidget(ShellIsland old) {
    super.didUpdateWidget(old);
    if (old.center != widget.center) {
      old.center.removeListener(_changed);
      widget.center.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.center.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void collapse() => widget.center.collapse();

  @override
  void feature(String id) => widget.center.feature(id);

  @override
  void hold() => widget.center.hold();

  @override
  void release() => widget.center.release();

  @override
  Widget build(BuildContext context) {
    final center = widget.center;
    final stage = center.stage;
    final live = center.featured;
    if (live != null) _last = live;
    // Once the last thing is over, the island still says it while it goes.
    final featured = live ?? _last;
    final expanded = stage == IslandStage.expanded;
    final shown = stage != IslandStage.hidden && live != null;
    final width = _measured.width;
    final origin = shellIslandOrigin(
      width: width,
      windowWidth: widget.windowWidth,
      controlsLeft: widget.controlsLeft,
      titleRight: widget.titleRight,
      expanded: expanded,
      buttonsLeft: widget.buttonsLeft,
      buttonsBottom: widget.buttonsBottom,
    );
    if (shown != _wasShown || expanded != _wasExpanded) {
      _growing = shown && (!_wasShown || (expanded && !_wasExpanded));
      _wasShown = shown;
      _wasExpanded = expanded;
    }
    final spring = _spring;
    return SpringBuilder(
      value: origin.dx,
      spring: spring,
      builder: (context, left, _) => SpringBuilder(
        value: origin.dy,
        spring: spring,
        builder: (context, top, _) => SpringBuilder(
          value: width,
          spring: spring,
          builder: (context, w, _) => SpringBuilder(
            value: _measured.height,
            spring: spring,
            builder: (context, h, _) => SpringBuilder(
              value: expanded ? 1 : 0,
              spring: spring,
              builder: (context, open, _) => SpringBuilder(
                value: shown ? 1 : 0,
                from: 0,
                spring: spring,
                builder: (context, appear, _) {
                  if (appear <= .01 && !shown) return const SizedBox.shrink();
                  // The shape first, then what it says; going away, the
                  // other way round.
                  final shape = (appear / WhisperIslandMotion.shapeBy).clamp(
                    0.0,
                    1.0,
                  );
                  final says =
                      ((appear - WhisperIslandMotion.contentFrom) /
                              (1 - WhisperIslandMotion.contentFrom))
                          .clamp(0.0, 1.0);
                  return Positioned(
                    left: left,
                    top: top,
                    width: math.max(w, _compactHeight),
                    height: math.max(h, _compactHeight),
                    child: Opacity(
                      opacity: shape,
                      child: Transform.scale(
                        // From 0.6, and past 1 for a moment coming in.
                        scale: .6 + .4 * math.max(appear, 0),
                        child: _capsule(
                          context,
                          featured,
                          expanded,
                          open: open.clamp(0.0, 1.0),
                          says: says,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [open] is how far it has opened, for the corners and the shadow, which
  /// change with the shape instead of at once; [says] how much of what is
  /// inside shows yet.
  Widget _capsule(
    BuildContext context,
    IslandActivity? featured,
    bool expanded, {
    required double open,
    required double says,
  }) {
    if (featured == null) return const SizedBox.shrink();
    final radius = BorderRadius.circular(lerpDouble(17, 26, open)!);
    final growing = _growing;
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        button: !expanded,
        label: featured.presenter.describe(context),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: radius,
            boxShadow: BoxShadow.lerpList(
              WhisperShadow.islandClosed,
              WhisperShadow.islandOpen,
              open,
            ),
          ),
          child: ClipRRect(
            borderRadius: radius,
            // Centred, so what is inside stays where it is on screen while
            // the shape grows or shrinks around it.
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minWidth: 0,
              maxWidth: expanded ? _openWidth : _compactMax,
              minHeight: 0,
              maxHeight: double.infinity,
              child: IslandSizeReport(
                onSize: (size) {
                  if (!mounted) return;
                  if ((size.width - _measured.width).abs() > .5 ||
                      (size.height - _measured.height).abs() > .5) {
                    setState(() {
                      if (_wasShown && _wasExpanded == expanded) {
                        _growing = size.height >= _measured.height;
                      }
                      _measured = size;
                    });
                  }
                },
                child: islandVeil(
                  IslandMorph(
                    identity: expanded ? 'open' : 'small ${featured.id}',
                    spring: _spring,
                    from: growing
                        ? WhisperIslandMotion.near
                        : 1 / WhisperIslandMotion.near,
                    child: expanded
                        ? _open(context, featured)
                        : _compact(context, featured),
                  ),
                  shown: says,
                  scale: 1,
                  blur: (1 - says) * WhisperIslandMotion.blur,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `.isl-c`.
  Widget _compact(BuildContext context, IslandActivity featured) {
    const type = WhisperType(touch: false);
    final presenter = featured.presenter;
    final count = widget.center.listed.length;
    Widget body;
    if (presenter is MomentPresenter) {
      final m = (presenter as MomentPresenter).moment(context);
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 20,
            child: Center(child: IslandGlyph(child: m.leading)),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              m.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: type.note,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ),
          if (m.value != null) ...[
            const SizedBox(width: 7),
            IslandFigures(
              m.value!,
              style: TextStyle(
                fontSize: type.note,
                fontWeight: FontWeight.w500,
                color: Radix.whiteA8,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (count > 1) ...[
            const SizedBox(width: 8),
            Container(
              constraints: const BoxConstraints(minWidth: 16),
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Radix.whiteA4,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(fontSize: type.tiny, color: Colors.white),
              ),
            ),
          ],
        ],
      );
    } else {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.center.tap,
        child: SizedBox(
          width: 200,
          height: _compactHeight,
          child: presenter.compact(context),
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.center.tap,
      child: Container(
        height: _compactHeight,
        padding: const EdgeInsets.fromLTRB(10, 0, 13, 0),
        child: body,
      ),
    );
  }

  /// `.isl-e`, a `.mo` for each.
  Widget _open(BuildContext context, IslandActivity featured) {
    final activities = [featured, ...widget.center.others];
    // Tapped again it goes small. Its buttons keep their own taps.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.center.tap,
      child: SizedBox(
        width: _openWidth,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: IslandRows(
            children: [
              for (final activity in activities)
                KeyedSubtree(
                  key: ValueKey(activity.id),
                  child: activity.presenter is MomentPresenter
                      ? _Moment(
                          moment: (activity.presenter as MomentPresenter)
                              .moment(context),
                        )
                      : activity == featured
                      ? activity.presenter.featured(context, this)
                      : activity.presenter.row(context, this),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Moment extends StatelessWidget {
  const _Moment({required this.moment});

  final IslandMoment moment;

  @override
  Widget build(BuildContext context) {
    const type = WhisperType(touch: false);
    final m = moment;
    if (m.answers.isNotEmpty) return IslandAskCard(moment: m);
    const faint = Radix.whiteA3;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(7),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: faint, shape: BoxShape.circle),
                child: Center(child: IslandGlyph(child: m.leading)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      m.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.note,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    if (m.detail.isNotEmpty)
                      IslandFigures(
                        m.detail,
                        style: TextStyle(
                          fontSize: type.tiny,
                          height: 1.35,
                          color: Radix.whiteA8,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
              ),
              // Done, the button shrinks away where it was.
              IslandMorph(
                identity: m.onStop != null,
                spring: WhisperSprings.snappy,
                from: WhisperIslandMotion.pop,
                to: WhisperIslandMotion.pop,
                blur: WhisperIslandMotion.figureBlur,
                alignment: Alignment.centerRight,
                child: m.onStop == null
                    ? const SizedBox(height: 28)
                    : Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Pressable(
                          onTap: m.onStop,
                          radius: WhisperRadius.capsule,
                          label: m.stopLabel,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: faint,
                              shape: BoxShape.circle,
                            ),
                            child: const Center(
                              child: WhisperIcon(
                                WhisperGlyph.x,
                                size: 13,
                                weight: 2,
                                color: Colors.white,
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
    );
  }
}
