import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';

class WhisperSettingsSlider extends StatelessWidget {
  const WhisperSettingsSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.minLabel,
    required this.maxLabel,
    required this.onChanged,
    required this.onChangeEnd,
    this.anchorValue,
    this.anchorLabel,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final String minLabel;
  final String maxLabel;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final double? anchorValue;
  final String? anchorLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = context.whisperPalette;
    final isDark = theme.brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final anchorFraction = anchorValue == null
        ? null
        : ((anchorValue! - min) / (max - min)).clamp(0.0, 1.0);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: isDark ? 0.62 : 0.68),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.10)
              : colors.outlineVariant.withValues(alpha: 0.72),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              liveRegion: true,
              value: valueLabel,
              child: AnimatedContainer(
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: LinearGradient(
                    colors: <Color>[colors.primary, colors.secondary],
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: colors.primary.withValues(alpha: 0.24),
                      blurRadius: 16,
                      spreadRadius: -5,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  valueLabel,
                  key: ValueKey<String>(valueLabel),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colors.onPrimary,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SliderTheme(
              data: theme.sliderTheme.copyWith(
                trackHeight: 8,
                trackShape: _WhisperGradientSliderTrackShape(
                  primary: colors.primary,
                  secondary: colors.secondary,
                  inactive: colors.onSurface.withValues(
                    alpha: isDark ? 0.18 : 0.12,
                  ),
                  anchor: colors.onSurfaceVariant,
                  anchorFraction: anchorFraction,
                ),
                thumbShape: _WhisperGlassSliderThumbShape(
                  primary: colors.primary,
                  secondary: colors.secondary,
                  surface: palette.surfaceElevated,
                  border: isDark
                      ? Colors.white.withValues(alpha: 0.72)
                      : Colors.white,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
                overlayColor: colors.primary.withValues(alpha: 0.14),
                activeTickMarkColor: Colors.transparent,
                inactiveTickMarkColor: Colors.transparent,
                showValueIndicator: ShowValueIndicator.never,
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                label: valueLabel,
                semanticFormatterCallback: (_) => valueLabel,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                children: <Widget>[
                  Text(minLabel, style: _labelStyle(context)),
                  if (anchorLabel != null)
                    Expanded(
                      child: Text(
                        anchorLabel!,
                        textAlign: TextAlign.center,
                        style: _labelStyle(context).copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  Text(maxLabel, style: _labelStyle(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _labelStyle(BuildContext context) {
    return Theme.of(context).textTheme.labelMedium?.copyWith(
          color: context.whisperPalette.textMuted,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ) ??
        TextStyle(color: context.whisperPalette.textMuted);
  }
}

class _WhisperGradientSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _WhisperGradientSliderTrackShape({
    required this.primary,
    required this.secondary,
    required this.inactive,
    required this.anchor,
    required this.anchorFraction,
  });

  final Color primary;
  final Color secondary;
  final Color inactive;
  final Color anchor;
  final double? anchorFraction;

  @override
  bool get isRounded => true;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) {
      return;
    }
    final canvas = context.canvas;
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(trackRect.height / 2);
    final track = RRect.fromRectAndRadius(trackRect, radius);
    final enabledOpacity = isEnabled ? 1.0 : 0.38;
    canvas.drawRRect(
      track,
      Paint()..color = inactive.withValues(alpha: inactive.a * enabledOpacity),
    );

    final activeRect = textDirection == TextDirection.ltr
        ? Rect.fromLTRB(
            trackRect.left,
            trackRect.top,
            thumbCenter.dx.clamp(trackRect.left, trackRect.right),
            trackRect.bottom,
          )
        : Rect.fromLTRB(
            thumbCenter.dx.clamp(trackRect.left, trackRect.right),
            trackRect.top,
            trackRect.right,
            trackRect.bottom,
          );
    if (activeRect.width > 0) {
      final gradient = LinearGradient(
        begin: textDirection == TextDirection.ltr
            ? Alignment.centerLeft
            : Alignment.centerRight,
        end: textDirection == TextDirection.ltr
            ? Alignment.centerRight
            : Alignment.centerLeft,
        colors: <Color>[
          primary.withValues(alpha: enabledOpacity),
          secondary.withValues(alpha: enabledOpacity),
        ],
      );
      canvas.save();
      canvas.clipRect(activeRect);
      canvas.drawRRect(
        track,
        Paint()..shader = gradient.createShader(trackRect),
      );
      canvas.restore();
    }

    if (anchorFraction case final fraction?) {
      final resolvedFraction =
          textDirection == TextDirection.ltr ? fraction : 1 - fraction;
      final anchorCenter = Offset(
        trackRect.left + trackRect.width * resolvedFraction,
        trackRect.center.dy,
      );
      canvas.drawCircle(
        anchorCenter,
        3.2,
        Paint()..color = anchor.withValues(alpha: 0.72 * enabledOpacity),
      );
      canvas.drawCircle(
        anchorCenter,
        1.5,
        Paint()..color = Colors.white.withValues(alpha: enabledOpacity),
      );
    }
  }
}

class _WhisperGlassSliderThumbShape extends SliderComponentShape {
  const _WhisperGlassSliderThumbShape({
    required this.primary,
    required this.secondary,
    required this.surface,
    required this.border,
  });

  final Color primary;
  final Color secondary;
  final Color surface;
  final Color border;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return const Size.square(26);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final enabledOpacity = enableAnimation.value.clamp(0.38, 1.0);
    final radius = 10.5 + activationAnimation.value * 1.5;
    final path = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    canvas.drawShadow(
      path,
      Colors.black.withValues(alpha: 0.26 * enabledOpacity),
      5 + activationAnimation.value * 3,
      true,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = surface.withValues(alpha: enabledOpacity),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = border.withValues(alpha: enabledOpacity),
    );
    final innerRect = Rect.fromCircle(center: center, radius: 5.5);
    canvas.drawCircle(
      center,
      5.5,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            primary.withValues(alpha: enabledOpacity),
            secondary.withValues(alpha: enabledOpacity),
          ],
        ).createShader(innerRect),
    );
  }
}
