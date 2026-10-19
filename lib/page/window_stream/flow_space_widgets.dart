import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../helper/device_form_factor.dart';
import '../../widget/device_glyph.dart';
import '../../window_stream/core/window_stream_models.dart';
import 'flow_app_icon.dart';
import 'flow_space_theme.dart';

/// Section heading in the space: small, quiet, with optional trailing.
class FlowSectionHeader extends StatelessWidget {
  const FlowSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.count,
    this.accessory,
  });

  final String title;
  final Widget? trailing;
  final int? count;

  /// Right after the title and count (a filter chip, say).
  final Widget? accessory;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            color: colors.label,
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        if (count != null && count! > 0) ...[
          const SizedBox(width: 8),
          // The count rolls as a search narrows the list; what follows it
          // slides along instead of jumping.
          AnimatedSize(
            duration: FlowSpaceTokens.quickDuration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            child: AnimatedSwitcher(
              duration: FlowSpaceTokens.quickDuration,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, 0.35),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Text(
                '$count',
                key: ValueKey(count),
                style: TextStyle(
                  color: colors.tertiaryLabel,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ],
        if (accessory != null) ...[const SizedBox(width: 12), accessory!],
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// A capsule that switches a filter on and off ("显示系统应用"): grey when
/// off, tinted with a check when on.
class FlowToggleChip extends StatelessWidget {
  const FlowToggleChip({
    super.key,
    required this.label,
    required this.value,
    required this.tint,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final Color tint;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final duration = flowReduceMotion(context)
        ? Duration.zero
        : FlowSpaceTokens.quickDuration;
    return Semantics(
      button: true,
      toggled: value,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onChanged(!value);
        },
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            color: value
                ? tint.withValues(alpha: colors.dark ? 0.24 : 0.13)
                : (colors.dark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.05)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSize(
                duration: duration,
                curve: Curves.easeOutCubic,
                child: value
                    ? Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          CupertinoIcons.checkmark,
                          size: 12,
                          color: tint,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              AnimatedDefaultTextStyle(
                duration: duration,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: value ? tint : colors.secondaryLabel,
                ),
                child: Text(label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [tablet]: the device said it is one (`DeviceFormFactors`); show it with
/// [DeviceGlyph], which stands the tablet upright.
IconData flowDeviceGlyph(WindowStreamPlatform platform, {bool tablet = false}) {
  return switch (platform) {
    WindowStreamPlatform.android || WindowStreamPlatform.ios =>
      tablet ? tabletGlyph : CupertinoIcons.device_phone_portrait,
    WindowStreamPlatform.macos => CupertinoIcons.device_laptop,
    WindowStreamPlatform.windows => CupertinoIcons.desktopcomputer,
    WindowStreamPlatform.linux => CupertinoIcons.desktopcomputer,
  };
}

/// One device on the shelf: a small drawing of the device in its own colour,
/// its open windows on the drawn screen, name and status underneath.
/// Selected: lifted, with a halo of its hue.
class FlowDeviceCard extends StatefulWidget {
  const FlowDeviceCard({
    super.key,
    required this.name,
    required this.subtitle,
    required this.platform,
    required this.hue,
    required this.selected,
    required this.onTap,
    this.windowCount = 0,
    this.problem = false,
    this.receiving = false,
    this.tablet = false,
  });

  final String name;
  final String subtitle;
  final WindowStreamPlatform platform;

  /// A phone platform's tablet: drawn wider, without the island.
  final bool tablet;
  final Color hue;
  final bool selected;
  final VoidCallback onTap;
  final int windowCount;
  final bool problem;

  /// A window sent from here just landed on this device: swell briefly.
  final bool receiving;

  static const double width = 148;
  static const double height = 128;

  @override
  State<FlowDeviceCard> createState() => _FlowDeviceCardState();
}

class _FlowDeviceCardState extends State<FlowDeviceCard> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final reduceMotion = flowReduceMotion(context);
    final scale = widget.receiving
        ? 1.07
        : _pressed
        ? 0.96
        : (_hovered && !widget.selected ? 1.02 : 1.0);
    final statusColor = widget.problem
        ? FlowSpaceTokens.paused
        : FlowSpaceTokens.live;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(22),
      side: BorderSide(
        color: widget.selected
            ? widget.hue.withValues(alpha: 0.6)
            : colors.hairline,
        width: widget.selected ? 1.5 : 1,
      ),
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.name}, ${widget.subtitle}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: () {
            HapticFeedback.selectionClick();
            widget.onTap();
          },
          child: AnimatedScale(
            duration: reduceMotion
                ? Duration.zero
                : FlowSpaceTokens.quickDuration,
            curve: const SpringCurve(FlowSpaceTokens.snappySpring, 0.3),
            scale: scale,
            child: AnimatedContainer(
              duration: reduceMotion
                  ? Duration.zero
                  : FlowSpaceTokens.quickDuration,
              curve: Curves.easeOutCubic,
              width: FlowDeviceCard.width,
              height: FlowDeviceCard.height,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              decoration: ShapeDecoration(
                shape: shape,
                color: widget.selected
                    ? colors.raised
                    : colors.raised.withValues(alpha: colors.dark ? 0.55 : 0.7),
                shadows: widget.selected
                    ? colors.liftedShadow(widget.hue)
                    : const [],
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Opacity(
                      opacity: widget.problem ? 0.55 : 1,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: widget.selected ? 1 : 0),
                        duration: reduceMotion
                            ? Duration.zero
                            : FlowSpaceTokens.springDuration,
                        curve: const SpringCurve(),
                        builder: (context, lit, _) => CustomPaint(
                          size: Size.infinite,
                          painter: _DevicePainter(
                            platform: widget.platform,
                            tablet: widget.tablet,
                            hue: widget.hue,
                            lit: lit,
                            windows: widget.windowCount,
                            dark: colors.dark,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.label,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.secondaryLabel,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
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

/// A phone, laptop or desktop in outline; its screen fills with the
/// device's colour as it is selected ([lit] 0…1), and each open window
/// shows as a small card on it.
class _DevicePainter extends CustomPainter {
  const _DevicePainter({
    required this.platform,
    required this.tablet,
    required this.hue,
    required this.lit,
    required this.windows,
    required this.dark,
  });

  final WindowStreamPlatform platform;
  final bool tablet;
  final Color hue;
  final double lit;
  final int windows;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final body = dark ? const Color(0xFF8E8E93) : const Color(0xFF3A3A3C);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Color.lerp(body.withValues(alpha: 0.55), hue, lit)!;
    final Rect screen;
    final center = size.center(Offset.zero);
    switch (platform) {
      case WindowStreamPlatform.android || WindowStreamPlatform.ios when tablet:
        // Held upright: about 3:4, thin even bezels, a camera dot.
        final h = size.height;
        final w = h * 0.76;
        final outer = RRect.fromRectAndRadius(
          Rect.fromCenter(center: center, width: w, height: h),
          Radius.circular(w * 0.1),
        );
        screen = outer.outerRect.deflate(4.5);
        _screen(
          canvas,
          RRect.fromRectAndRadius(screen, Radius.circular(w * 0.06)),
        );
        canvas.drawRRect(outer, stroke);
        canvas.drawCircle(
          Offset(center.dx, outer.top + 2.4),
          1.1,
          Paint()..color = body.withValues(alpha: 0.8),
        );
      case WindowStreamPlatform.android || WindowStreamPlatform.ios:
        final h = size.height;
        final w = h * 0.52;
        final outer = RRect.fromRectAndRadius(
          Rect.fromCenter(center: center, width: w, height: h),
          Radius.circular(w * 0.2),
        );
        screen = outer.outerRect.deflate(3.5);
        _screen(
          canvas,
          RRect.fromRectAndRadius(screen, Radius.circular(w * 0.15)),
        );
        canvas.drawRRect(outer, stroke);
        // The island.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(center.dx, screen.top + 4.5),
              width: w * 0.3,
              height: 3.5,
            ),
            const Radius.circular(2),
          ),
          Paint()..color = body.withValues(alpha: 0.8),
        );
      case WindowStreamPlatform.macos:
        final w = size.width * 0.86;
        final lidH = size.height * 0.78;
        final lid = Rect.fromLTWH(
          center.dx - w * 0.42,
          center.dy - size.height / 2,
          w * 0.84,
          lidH,
        );
        final outer = RRect.fromRectAndRadius(lid, const Radius.circular(6));
        screen = lid.deflate(3.5);
        _screen(
          canvas,
          RRect.fromRectAndRadius(screen, const Radius.circular(3)),
        );
        canvas.drawRRect(outer, stroke);
        final base = Path()
          ..moveTo(center.dx - w / 2, lid.bottom + 1)
          ..lineTo(center.dx + w / 2, lid.bottom + 1)
          ..lineTo(center.dx + w / 2 - 4, lid.bottom + 6)
          ..lineTo(center.dx - w / 2 + 4, lid.bottom + 6)
          ..close();
        canvas.drawPath(base, Paint()..color = stroke.color);
      case WindowStreamPlatform.windows || WindowStreamPlatform.linux:
        final w = size.width * 0.8;
        final monitor = Rect.fromLTWH(
          center.dx - w / 2,
          center.dy - size.height / 2,
          w,
          size.height * 0.74,
        );
        final outer = RRect.fromRectAndRadius(
          monitor,
          const Radius.circular(5),
        );
        screen = monitor.deflate(3.5);
        _screen(
          canvas,
          RRect.fromRectAndRadius(screen, const Radius.circular(2)),
        );
        canvas.drawRRect(outer, stroke);
        final neck = Paint()
          ..color = stroke.color
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          Offset(center.dx, monitor.bottom),
          Offset(center.dx, monitor.bottom + size.height * 0.16),
          neck,
        );
        canvas.drawLine(
          Offset(center.dx - w * 0.18, monitor.bottom + size.height * 0.2),
          Offset(center.dx + w * 0.18, monitor.bottom + size.height * 0.2),
          neck,
        );
    }
    // Open windows as little cards, fanned on the screen.
    final count = windows.clamp(0, 3);
    for (var i = 0; i < count; i++) {
      final cw = screen.width * 0.46;
      final ch = cw * (screen.height > screen.width ? 1.25 : 0.7);
      final offset = (i - (count - 1) / 2) * 7.0;
      final card = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: screen.center.translate(offset, offset * 0.6),
          width: cw,
          height: ch,
        ),
        const Radius.circular(3),
      );
      canvas.drawRRect(
        card.shift(const Offset(0, 1)),
        Paint()..color = Colors.black.withValues(alpha: 0.15),
      );
      canvas.drawRRect(
        card,
        Paint()..color = Colors.white.withValues(alpha: 0.92),
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(card.left, card.top, card.width, 4),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()..color = hue.withValues(alpha: 0.7),
      );
    }
  }

  void _screen(Canvas canvas, RRect screen) {
    final off = dark ? const Color(0xFF1C1C1E) : const Color(0xFFE9E9EE);
    final top = Color.lerp(off, Color.lerp(hue, Colors.white, 0.35)!, lit)!;
    final bottom = Color.lerp(off, hue, lit)!;
    canvas.drawRRect(
      screen,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [top, bottom],
        ).createShader(screen.outerRect),
    );
  }

  @override
  bool shouldRepaint(_DevicePainter old) =>
      old.lit != lit ||
      old.windows != windows ||
      old.hue != hue ||
      old.dark != dark ||
      old.platform != platform ||
      old.tablet != tablet;
}

/// Which way windows go between this device and the selected one: two
/// cards, each with a little diagram of the direction, the chosen one
/// tinted with the device's colour.
class FlowDirectionPicker extends StatelessWidget {
  const FlowDirectionPicker({
    super.key,
    required this.sendSelected,
    required this.hue,
    required this.devicePlatform,
    required this.openTitle,
    required this.openDetail,
    required this.sendTitle,
    required this.sendDetail,
    required this.onChanged,
    this.compact = false,
    this.deviceTablet = false,
  });

  final bool sendSelected;
  final Color hue;
  final WindowStreamPlatform devicePlatform;

  /// The other device is a tablet (see [flowDeviceGlyph]).
  final bool deviceTablet;
  final String openTitle;
  final String openDetail;
  final String sendTitle;
  final String sendDetail;
  final ValueChanged<bool> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    Widget option(bool send) => Expanded(
      child: _DirectionOption(
        selected: sendSelected == send,
        hue: hue,
        send: send,
        devicePlatform: devicePlatform,
        deviceTablet: deviceTablet,
        title: send ? sendTitle : openTitle,
        detail: send ? sendDetail : openDetail,
        compact: compact,
        onTap: () => onChanged(send),
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Row(
        children: [option(false), const SizedBox(width: 10), option(true)],
      ),
    );
  }
}

class _DirectionOption extends StatefulWidget {
  const _DirectionOption({
    required this.selected,
    required this.hue,
    required this.send,
    required this.devicePlatform,
    required this.deviceTablet,
    required this.title,
    required this.detail,
    required this.compact,
    required this.onTap,
  });

  final bool selected;
  final Color hue;
  final bool send;
  final WindowStreamPlatform devicePlatform;
  final bool deviceTablet;
  final String title;
  final String detail;
  final bool compact;
  final VoidCallback onTap;

  @override
  State<_DirectionOption> createState() => _DirectionOptionState();
}

class _DirectionOptionState extends State<_DirectionOption> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final selected = widget.selected;
    final here = Platform.isMacOS
        ? CupertinoIcons.device_laptop
        : (Platform.isAndroid || Platform.isIOS)
        ? flowDeviceGlyph(
            Platform.isIOS
                ? WindowStreamPlatform.ios
                : WindowStreamPlatform.android,
            tablet: DeviceFormFactors.shared.localIsTablet,
          )
        : CupertinoIcons.desktopcomputer;
    final there = flowDeviceGlyph(
      widget.devicePlatform,
      tablet: widget.deviceTablet,
    );
    final glyph = selected ? widget.hue : colors.secondaryLabel;
    return Semantics(
      button: true,
      selected: selected,
      label: '${widget.title}, ${widget.detail}',
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: () {
          if (!selected) {
            HapticFeedback.selectionClick();
            widget.onTap();
          }
        },
        child: AnimatedScale(
          duration: FlowSpaceTokens.quickDuration,
          scale: _pressed ? 0.97 : 1,
          child: AnimatedContainer(
            duration: FlowSpaceTokens.quickDuration,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: widget.compact ? 9 : 11,
            ),
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(
                  color: selected
                      ? widget.hue.withValues(alpha: 0.55)
                      : colors.hairline,
                  width: selected ? 1.5 : 1,
                ),
              ),
              color: selected
                  ? widget.hue.withValues(alpha: colors.dark ? 0.18 : 0.08)
                  : colors.raised.withValues(alpha: colors.dark ? 0.5 : 0.7),
            ),
            child: Row(
              children: [
                // From → to: the arrow points the way windows go.
                DeviceGlyph(widget.send ? here : there, size: 18, color: glyph),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: _FlowArrow(color: glyph, active: selected),
                ),
                DeviceGlyph(widget.send ? there : here, size: 18, color: glyph),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? colors.label
                              : colors.secondaryLabel,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (!widget.compact)
                        Text(
                          widget.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.tertiaryLabel,
                            fontSize: 11.5,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Three dots travelling left to right while [active].
class _FlowArrow extends StatefulWidget {
  const _FlowArrow({required this.color, required this.active});

  final Color color;
  final bool active;

  @override
  State<_FlowArrow> createState() => _FlowArrowState();
}

class _FlowArrowState extends State<_FlowArrow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_FlowArrow old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final still = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    if (widget.active && !still) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else {
      _controller
        ..stop()
        ..value = 0.5;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 1 while the wave passes dot [i], fading to 0 behind it.
  double _glow(int i) {
    final phase = (_controller.value * 3 - i) % 3;
    return phase < 1 ? 1 - phase : 0;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                width: 3.5,
                height: 3.5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(
                    alpha: widget.active ? 0.3 + 0.7 * _glow(i) : 0.45,
                  ),
                ),
              ),
            ),
          Icon(CupertinoIcons.chevron_right, size: 11, color: widget.color),
        ],
      ),
    );
  }
}

/// An app in the grid: icon, label, running dot. Springs on hover/press.
class FlowAppTile extends StatefulWidget {
  const FlowAppTile({
    super.key,
    required this.label,
    required this.hue,
    required this.onTap,
    this.icon,
    this.running = false,
    this.onDesktop = false,
    this.busy = false,
    this.iconSize = 60,
  });

  final String label;
  final Color hue;
  final Uint8List? icon;
  final bool running;
  final bool onDesktop;
  final bool busy;
  final double iconSize;
  final void Function(Rect globalRect) onTap;

  @override
  State<FlowAppTile> createState() => _FlowAppTileState();
}

class _FlowAppTileState extends State<FlowAppTile> {
  bool _hovered = false;
  bool _pressed = false;
  final _iconKey = GlobalKey();

  void _tap() {
    final box = _iconKey.currentContext?.findRenderObject() as RenderBox?;
    final rect = box == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;
    HapticFeedback.selectionClick();
    widget.onTap(rect);
  }

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final reduceMotion = flowReduceMotion(context);
    final scale = _pressed ? 0.9 : (_hovered ? 1.06 : 1.0);
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.busy ? null : _tap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                duration: reduceMotion
                    ? Duration.zero
                    : FlowSpaceTokens.quickDuration,
                curve: const SpringCurve(FlowSpaceTokens.snappySpring, 0.32),
                scale: scale,
                child: AnimatedContainer(
                  duration: FlowSpaceTokens.quickDuration,
                  decoration: ShapeDecoration(
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(
                        widget.iconSize * 0.225,
                      ),
                    ),
                    shadows: _hovered
                        ? colors.liftedShadow(widget.hue)
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: colors.dark ? 0.35 : 0.1,
                              ),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                  ),
                  child: Stack(
                    key: _iconKey,
                    children: [
                      FlowAppIcon(
                        label: widget.label,
                        icon: widget.icon,
                        hue: widget.hue,
                        size: widget.iconSize,
                      ),
                      if (widget.busy)
                        Positioned.fill(
                          child: ClipPath(
                            clipper: ShapeBorderClipper(
                              shape: RoundedSuperellipseBorder(
                                borderRadius: BorderRadius.circular(
                                  widget.iconSize * 0.225,
                                ),
                              ),
                            ),
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.35),
                              child: const Center(
                                child: CupertinoActivityIndicator(
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 7),
              SizedBox(
                width: widget.iconSize + 28,
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.label,
                    fontSize: 12,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              AnimatedOpacity(
                duration: FlowSpaceTokens.quickDuration,
                opacity: widget.running || widget.onDesktop ? 1 : 0,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: widget.onDesktop
                        ? widget.hue
                        : colors.secondaryLabel,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A live window in the windows column: thumbnail, title, state capsule,
/// and controls on hover (always visible on touch).
class FlowWindowCard extends StatefulWidget {
  const FlowWindowCard({
    super.key,
    required this.title,
    required this.deviceName,
    required this.hue,
    required this.status,
    required this.statusLabel,
    required this.onFocus,
    required this.onClose,
    required this.closeLabel,
    required this.pauseLabel,
    required this.resumeLabel,
    this.onPause,
    this.onResume,
    this.thumbnail,
    this.icon,
    this.touch = false,
  });

  final String title;
  final String deviceName;
  final Color hue;
  final StreamStatus status;
  final String statusLabel;
  final Uint8List? thumbnail;
  final Uint8List? icon;
  final VoidCallback onFocus;
  final VoidCallback onClose;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final String closeLabel;
  final String pauseLabel;
  final String resumeLabel;
  final bool touch;

  @override
  State<FlowWindowCard> createState() => _FlowWindowCardState();
}

class _FlowWindowCardState extends State<FlowWindowCard> {
  bool _hovered = false;

  Color get _statusColor => switch (widget.status) {
    StreamStatus.live => FlowSpaceTokens.live,
    StreamStatus.suspended => FlowSpaceTokens.paused,
    StreamStatus.opening ||
    StreamStatus.reconnecting => FlowSpaceTokens.reconnecting,
    _ => FlowSpaceTokens.failed,
  };

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final paused = widget.status == StreamStatus.suspended;
    final showControls = widget.touch || _hovered;
    final shape = FlowSpaceTokens.card(18);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onFocus,
        child: AnimatedContainer(
          duration: FlowSpaceTokens.quickDuration,
          decoration: ShapeDecoration(
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                color: _hovered
                    ? widget.hue.withValues(alpha: 0.5)
                    : colors.hairline,
              ),
            ),
            color: colors.raised,
            shadows: _hovered
                ? colors.liftedShadow(widget.hue)
                : colors.cardShadow,
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 10,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: colors.dark
                            ? Colors.black
                            : const Color(0xFFE5E5EA),
                      ),
                      if (widget.thumbnail != null)
                        AnimatedOpacity(
                          duration: FlowSpaceTokens.quickDuration,
                          opacity: paused ? 0.55 : 1,
                          child: Image.memory(
                            widget.thumbnail!,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                        )
                      else
                        Center(
                          child: FlowAppIcon(
                            label: widget.title,
                            icon: widget.icon,
                            hue: widget.hue,
                            size: 44,
                          ),
                        ),
                      Positioned(
                        top: 8,
                        left: 8,
                        child: FlowGlass(
                          radius: FlowSpaceTokens.capsuleRadius,
                          tint: Colors.black.withValues(alpha: 0.38),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _PulsingDot(
                                color: _statusColor,
                                pulse:
                                    widget.status ==
                                        StreamStatus.reconnecting ||
                                    widget.status == StreamStatus.opening,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                widget.statusLabel,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: AnimatedOpacity(
                          duration: FlowSpaceTokens.quickDuration,
                          opacity: showControls ? 1 : 0,
                          child: IgnorePointer(
                            ignoring: !showControls,
                            child: FlowGlass(
                              radius: FlowSpaceTokens.capsuleRadius,
                              tint: Colors.black.withValues(alpha: 0.42),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (paused && widget.onResume != null)
                                    _CapsuleButton(
                                      icon: CupertinoIcons.play_fill,
                                      tooltip: widget.resumeLabel,
                                      onPressed: widget.onResume!,
                                    )
                                  else if (!paused && widget.onPause != null)
                                    _CapsuleButton(
                                      icon: CupertinoIcons.pause_fill,
                                      tooltip: widget.pauseLabel,
                                      onPressed: widget.onPause!,
                                    ),
                                  _CapsuleButton(
                                    icon: CupertinoIcons.xmark,
                                    tooltip: widget.closeLabel,
                                    onPressed: widget.onClose,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: widget.hue,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.label,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        widget.deviceName,
                        maxLines: 1,
                        style: TextStyle(
                          color: colors.secondaryLabel,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CapsuleButton extends StatelessWidget {
  const _CapsuleButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: CupertinoButton(
        padding: const EdgeInsets.all(6),
        minimumSize: const Size(30, 30),
        onPressed: onPressed,
        child: Icon(icon, size: 15, color: Colors.white),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, required this.pulse});

  final Color color;
  final bool pulse;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.pulse && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulse && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1;
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
      opacity: widget.pulse
          ? Tween(begin: 0.35, end: 1.0).animate(_controller)
          : const AlwaysStoppedAnimation(1),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// A calm, centred explanation with an optional action.
/// A one-line status above a device's content, e.g. "this computer is
/// locked". Informational; the content below stays browsable.
class FlowNotice extends StatelessWidget {
  const FlowNotice({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(FlowSpaceTokens.cardRadius),
          side: BorderSide(color: colors.hairline),
        ),
        color: colors.raised,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: colors.secondaryLabel),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: colors.label,
                  fontSize: 14,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FlowEmptyState extends StatelessWidget {
  const FlowEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.actionLabel,
    this.onAction,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const CupertinoActivityIndicator(radius: 13)
              else
                Icon(icon, size: 40, color: colors.tertiaryLabel),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.label,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 6),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.secondaryLabel,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                CupertinoButton.filled(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  onPressed: onAction,
                  child: Text(
                    actionLabel!,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
