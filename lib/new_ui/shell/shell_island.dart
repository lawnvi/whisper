import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';
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
  });

  final Widget leading;
  final String title, detail;

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
      leading: m.leading,
      title: m.title,
      trailing: m.value == null
          ? null
          : Text(m.value!, style: IslandText.compactFigure(IslandColors.dim)),
    );
  }

  @override
  Widget featured(BuildContext context, IslandControls controls) {
    final m = moment(context);
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
          if (m.answers.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              children: [
                for (final answer in m.answers)
                  _MomentAction(label: answer.label, onTap: answer.onTap),
              ],
            ),
          ],
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
          m.leading,
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
            Text(value, style: IslandText.compactFigure(IslandColors.dim)),
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
  static const _openWidth = 372.0, _compactHeight = 34.0, _compactMax = 320.0;

  Size _measured = const Size(120, _compactHeight);

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
    final featured = center.featured;
    final expanded = stage == IslandStage.expanded;
    final shown = stage != IslandStage.hidden && featured != null;
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
    final spring = WhisperSprings.expressive;
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
              value: shown ? 1 : 0,
              from: 0,
              spring: spring,
              builder: (context, appear, _) {
                if (appear <= .01 && !shown) return const SizedBox.shrink();
                return Positioned(
                  left: left,
                  top: top,
                  width: math.max(w, _compactHeight),
                  height: math.max(h, _compactHeight),
                  child: Opacity(
                    opacity: appear.clamp(0, 1),
                    child: Transform.scale(
                      scale: .6 + .4 * appear.clamp(0, 1),
                      child: _capsule(context, featured, expanded),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _capsule(
    BuildContext context,
    IslandActivity? featured,
    bool expanded,
  ) {
    if (featured == null) return const SizedBox.shrink();
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        button: !expanded,
        label: featured.presenter.describe(context),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(expanded ? 26 : 17),
            boxShadow: expanded
                ? WhisperShadow.islandOpen
                : WhisperShadow.islandClosed,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(expanded ? 26 : 17),
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: 0,
              maxWidth: expanded ? _openWidth : _compactMax,
              minHeight: 0,
              maxHeight: double.infinity,
              child: _Measured(
                onSize: (size) {
                  if ((size.width - _measured.width).abs() > .5 ||
                      (size.height - _measured.height).abs() > .5) {
                    setState(() => _measured = size);
                  }
                },
                child: expanded
                    ? _open(context, featured)
                    : _compact(context, featured),
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
          SizedBox.square(dimension: 20, child: Center(child: m.leading)),
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
            Text(
              m.value!,
              style: TextStyle(
                fontSize: type.note,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: .62),
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
                color: Colors.white.withValues(alpha: .18),
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
          width: 260,
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
    return SizedBox(
      width: _openWidth,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final activity in activities)
              if (activity.presenter is MomentPresenter)
                _Moment(
                  moment: (activity.presenter as MomentPresenter).moment(
                    context,
                  ),
                )
              else
                activity == featured
                    ? activity.presenter.featured(context, this)
                    : activity.presenter.row(context, this),
          ],
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
    final faint = Colors.white.withValues(alpha: .14);
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
                child: Center(child: m.leading),
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
                      Text(
                        m.detail,
                        style: TextStyle(
                          fontSize: type.tiny,
                          height: 1.35,
                          color: Colors.white.withValues(alpha: .62),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
              ),
              if (m.onStop != null) ...[
                const SizedBox(width: 10),
                Pressable(
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
              ],
            ],
          ),
        ),
        if (m.answers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(49, 0, 7, 7),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final answer in m.answers)
                  Pressable(
                    onTap: answer.onTap,
                    radius: 15,
                    child: Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: answer.primary ? Colors.white : faint,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Text(
                        answer.label,
                        style: TextStyle(
                          fontSize: type.note,
                          fontWeight: FontWeight.w500,
                          color: answer.primary ? Colors.black : Colors.white,
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

class _Measured extends StatefulWidget {
  const _Measured({required this.onSize, required this.child});

  final ValueChanged<Size> onSize;
  final Widget child;

  @override
  State<_Measured> createState() => _MeasuredState();
}

class _MeasuredState extends State<_Measured> {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = context.findRenderObject();
      if (mounted && box is RenderBox && box.hasSize) {
        widget.onSize(box.size);
      }
    });
    return widget.child;
  }
}
