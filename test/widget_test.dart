import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  test('app theme exposes semantic colors for workspace states', () {
    final lightPalette = AppTheme.lightTheme.extension<WhisperColors>();
    final darkPalette = AppTheme.darkTheme.extension<WhisperColors>();

    expect(lightPalette, isNotNull);
    expect(darkPalette, isNotNull);
    expect(lightPalette!.accent, isNot(equals(lightPalette.ok)));
    expect(darkPalette!.bad, isNot(equals(darkPalette.warn)));
  });
}
