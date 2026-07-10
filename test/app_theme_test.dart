import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  test('title bars keep the same surface color as their pages', () {
    for (final theme in <ThemeData>[AppTheme.lightTheme, AppTheme.darkTheme]) {
      expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
      expect(theme.appBarTheme.backgroundColor, theme.colorScheme.surface);
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
    }
  });

  test('restores the original palette and rounded component treatment', () {
    final light = AppTheme.lightTheme;
    final dark = AppTheme.darkTheme;
    final lightPalette = light.extension<WhisperPalette>()!;
    final darkPalette = dark.extension<WhisperPalette>()!;

    expect(lightPalette.surfaceCanvas, const Color(0xFFF1F5F9));
    expect(lightPalette.messageOutgoing, const Color(0xFFEFF6FF));
    expect(darkPalette.surfaceCanvas, Colors.black);
    expect(darkPalette.messageOutgoing, const Color(0xFF181818));
    expect(_radiusOf(light.cardTheme.shape), 24);
    expect(_radiusOf(light.inputDecorationTheme.border), 16);
    expect(_radiusOf(light.chipTheme.shape), 999);
    expect(_radiusOf(light.listTileTheme.shape), 18);
  });

  test('desktop settings retain their centered width', () {
    expect(WhisperUi.settingsMaxWidth, 760);
  });
}

double _radiusOf(ShapeBorder? shape) {
  final borderRadius = switch (shape) {
    RoundedRectangleBorder(:final borderRadius) => borderRadius,
    OutlineInputBorder(:final borderRadius) => borderRadius,
    _ => throw StateError('Unexpected shape: $shape'),
  };
  final radius = borderRadius.resolve(TextDirection.ltr).topLeft;
  return radius.x;
}
