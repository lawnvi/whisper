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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      color: context.whisperPalette.textMuted,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ExcludeSemantics(
          child: Text(
            valueLabel,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurface,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        SliderTheme(
          data: theme.sliderTheme.copyWith(
            trackHeight: 4,
            trackShape: const RoundedRectSliderTrackShape(),
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 7,
              elevation: 0,
              pressedElevation: 0,
            ),
            activeTrackColor: colors.primary,
            inactiveTrackColor: colors.onSurface.withValues(alpha: 0.16),
            thumbColor: colors.primary,
            overlayColor: colors.primary.withValues(alpha: 0.10),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
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
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(minLabel, style: labelStyle),
              Text(maxLabel, style: labelStyle),
            ],
          ),
        ),
      ],
    );
  }
}
