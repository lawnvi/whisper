import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  test('app theme exposes semantic colors for workspace states', () {
    final lightPalette = AppTheme.lightTheme.extension<WhisperPalette>();
    final darkPalette = AppTheme.darkTheme.extension<WhisperPalette>();

    expect(lightPalette, isNotNull);
    expect(darkPalette, isNotNull);
    expect(lightPalette!.connected, isNot(equals(lightPalette.trusted)));
    expect(darkPalette!.danger, isNot(equals(darkPalette.warning)));
  });
}
