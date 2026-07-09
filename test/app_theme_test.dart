import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  group('Whisper theme tokens', () {
    test('light and dark themes expose the exact 12 semantic colors', () {
      final light = AppTheme.lightTheme;
      final dark = AppTheme.darkTheme;
      final lightPalette = light.extension<WhisperPalette>()!;
      final darkPalette = dark.extension<WhisperPalette>()!;

      expect(light.colorScheme.primary, const Color(0xFF2563EB));
      expect(light.colorScheme.surface, const Color(0xFFFFFFFF));
      expect(lightPalette.surfaceCanvas, const Color(0xFFF6F7F9));
      expect(lightPalette.surfaceMuted, const Color(0xFFEEF0F3));
      expect(lightPalette.surfaceElevated, const Color(0xFFFFFFFF));
      expect(lightPalette.borderSubtle, const Color(0xFFDDE1E6));
      expect(light.colorScheme.onSurface, const Color(0xFF171A1F));
      expect(lightPalette.textMuted, const Color(0xFF5F6875));
      expect(lightPalette.connected, const Color(0xFF1D6FD8));
      expect(lightPalette.trusted, const Color(0xFF18864B));
      expect(lightPalette.warning, const Color(0xFFB96A05));
      expect(lightPalette.danger, const Color(0xFFC93838));

      expect(dark.colorScheme.primary, const Color(0xFF7CA7FF));
      expect(dark.colorScheme.surface, const Color(0xFF111318));
      expect(darkPalette.surfaceCanvas, const Color(0xFF0B0D10));
      expect(darkPalette.surfaceMuted, const Color(0xFF1D2127));
      expect(darkPalette.surfaceElevated, const Color(0xFF171A20));
      expect(darkPalette.borderSubtle, const Color(0xFF303640));
      expect(dark.colorScheme.onSurface, const Color(0xFFF2F4F7));
      expect(darkPalette.textMuted, const Color(0xFFA1A9B5));
      expect(darkPalette.connected, const Color(0xFF77A9FF));
      expect(darkPalette.trusted, const Color(0xFF56C987));
      expect(darkPalette.warning, const Color(0xFFF2B45F));
      expect(darkPalette.danger, const Color(0xFFFF8A8A));
    });

    test('non-circular component radii do not exceed eight pixels', () {
      for (final theme in <ThemeData>[
        AppTheme.lightTheme,
        AppTheme.darkTheme,
      ]) {
        expect(_radiusOf(theme.cardTheme.shape), lessThanOrEqualTo(8));
        expect(
          _radiusOf(theme.inputDecorationTheme.border),
          lessThanOrEqualTo(8),
        );
        expect(_radiusOf(theme.chipTheme.shape), lessThanOrEqualTo(8));
        expect(_radiusOf(theme.listTileTheme.shape), lessThanOrEqualTo(8));
        expect(_radiusOf(theme.dialogTheme.shape), lessThanOrEqualTo(8));
      }
    });

    test('all global button themes reserve a 44 pixel target', () {
      for (final theme in <ThemeData>[
        AppTheme.lightTheme,
        AppTheme.darkTheme,
      ]) {
        expect(_minimumSize(theme.iconButtonTheme.style), const Size(44, 44));
        expect(_minimumSize(theme.textButtonTheme.style), const Size(44, 44));
        expect(_minimumSize(theme.filledButtonTheme.style), const Size(44, 44));
        expect(
          _minimumSize(theme.elevatedButtonTheme.style),
          const Size(44, 44),
        );
        expect(
          _minimumSize(theme.outlinedButtonTheme.style),
          const Size(44, 44),
        );
      }
    });

    test('uses system typography without a custom font family', () {
      for (final theme in <ThemeData>[
        AppTheme.lightTheme,
        AppTheme.darkTheme,
      ]) {
        final platformDefault = ThemeData(
          useMaterial3: true,
          brightness: theme.brightness,
        ).textTheme;
        final styles = _textStyles(theme.textTheme).toList();
        final defaultStyles = _textStyles(platformDefault).toList();
        for (var index = 0; index < styles.length; index += 1) {
          expect(styles[index]?.fontFamily, defaultStyles[index]?.fontFamily);
          expect(styles[index]?.letterSpacing, 0);
        }
      }
    });

    test('text and non-text semantic colors meet WCAG contrast', () {
      for (final theme in <ThemeData>[
        AppTheme.lightTheme,
        AppTheme.darkTheme,
      ]) {
        final palette = theme.extension<WhisperPalette>()!;
        final surface = theme.colorScheme.surface;

        expect(_contrast(theme.colorScheme.onSurface, surface),
            greaterThanOrEqualTo(4.5));
        expect(
            _contrast(palette.textMuted, surface), greaterThanOrEqualTo(4.5));
        for (final stateColor in <Color>[
          theme.colorScheme.primary,
          palette.connected,
          palette.trusted,
          palette.warning,
          palette.danger,
        ]) {
          expect(_contrast(stateColor, surface), greaterThanOrEqualTo(3));
        }
      }
    });
  });
}

double _radiusOf(ShapeBorder? shape) {
  final borderRadius = switch (shape) {
    RoundedRectangleBorder() => shape.borderRadius as BorderRadius,
    OutlineInputBorder() => shape.borderRadius,
    _ => throw TestFailure('Expected a rounded rectangular shape, got $shape'),
  };
  return borderRadius.topLeft.x;
}

Size? _minimumSize(ButtonStyle? style) {
  return style?.minimumSize?.resolve(<WidgetState>{});
}

double _contrast(Color foreground, Color background) {
  final lighter = foreground.computeLuminance() > background.computeLuminance()
      ? foreground.computeLuminance()
      : background.computeLuminance();
  final darker = foreground.computeLuminance() > background.computeLuminance()
      ? background.computeLuminance()
      : foreground.computeLuminance();
  return (lighter + 0.05) / (darker + 0.05);
}

Iterable<TextStyle?> _textStyles(TextTheme theme) sync* {
  yield theme.displayLarge;
  yield theme.displayMedium;
  yield theme.displaySmall;
  yield theme.headlineLarge;
  yield theme.headlineMedium;
  yield theme.headlineSmall;
  yield theme.titleLarge;
  yield theme.titleMedium;
  yield theme.titleSmall;
  yield theme.bodyLarge;
  yield theme.bodyMedium;
  yield theme.bodySmall;
  yield theme.labelLarge;
  yield theme.labelMedium;
  yield theme.labelSmall;
}
