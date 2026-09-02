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

  test('desktop settings retain their centered width', () {
    expect(WhisperUi.settingsMaxWidth, 760);
  });
}
