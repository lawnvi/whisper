import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:whisper/theme/whisper_motion.dart';
import 'package:whisper/theme/app_typography.dart';
import 'package:whisper/theme/whisper_ui.dart';

abstract final class WhisperUi {
  static const settingsMaxWidth = 760.0;
}

class AppTheme {
  const AppTheme._();

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Radix.blue9,
    onPrimary: Radix.white,
    primaryContainer: Radix.blue4,
    onPrimaryContainer: Radix.blue12,
    secondary: Radix.slate11,
    onSecondary: Radix.white,
    secondaryContainer: Radix.slate3,
    onSecondaryContainer: Radix.slate12,
    tertiary: Radix.amber9,
    onTertiary: Radix.slate12,
    tertiaryContainer: Radix.amber3,
    onTertiaryContainer: Radix.amber12,
    error: Radix.red9,
    onError: Radix.white,
    errorContainer: Radix.red3,
    onErrorContainer: Radix.red12,
    surface: Radix.white,
    onSurface: Radix.slate12,
    onSurfaceVariant: Radix.slate11,
    surfaceContainerLowest: Radix.white,
    surfaceContainerLow: Radix.slate1,
    surfaceContainer: Radix.slate2,
    surfaceContainerHigh: Radix.slate3,
    surfaceContainerHighest: Radix.slate4,
    outline: Radix.slate7,
    outlineVariant: Radix.slate6,
    inverseSurface: Radix.slate12,
    onInverseSurface: Radix.slate1,
    inversePrimary: Radix.blue8,
    shadow: Radix.black,
    scrim: Radix.black,
    surfaceTint: Radix.whiteA0,
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Radix.blueDark9,
    onPrimary: Radix.white,
    primaryContainer: Radix.blueDark4,
    onPrimaryContainer: Radix.blueDark12,
    secondary: Radix.slateDark11,
    onSecondary: Radix.slateDark1,
    secondaryContainer: Radix.slateDark4,
    onSecondaryContainer: Radix.slateDark12,
    tertiary: Radix.amberDark9,
    onTertiary: Radix.slateDark1,
    tertiaryContainer: Radix.amberDark3,
    onTertiaryContainer: Radix.amberDark12,
    error: Radix.redDark9,
    onError: Radix.white,
    errorContainer: Radix.redDark3,
    onErrorContainer: Radix.redDark12,
    surface: Radix.slateDark1,
    onSurface: Radix.slateDark12,
    onSurfaceVariant: Radix.slateDark11,
    surfaceContainerLowest: Radix.slateDark1,
    surfaceContainerLow: Radix.slateDark2,
    surfaceContainer: Radix.slateDark3,
    surfaceContainerHigh: Radix.slateDark4,
    surfaceContainerHighest: Radix.slateDark5,
    outline: Radix.slateDark7,
    outlineVariant: Radix.slateDark6,
    inverseSurface: Radix.slateDark12,
    onInverseSurface: Radix.slateDark1,
    inversePrimary: Radix.blue8,
    shadow: Radix.black,
    scrim: Radix.black,
    surfaceTint: Radix.whiteA0,
  );

  static ThemeData get lightTheme =>
      _buildTheme(_lightScheme, WhisperColors.light);

  static ThemeData get darkTheme =>
      _buildTheme(_darkScheme, WhisperColors.dark);

  /// The interface sets its own sizes and asks nothing else of the text theme:
  /// Material's letter spacing spreads Chinese apart, and its leading sits text
  /// off centre against the prototype's.
  static TextTheme _textTheme(TextTheme theme) {
    TextStyle? plain(TextStyle? style) => style?.copyWith(
      letterSpacing: 0,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return theme.copyWith(
      displayLarge: plain(theme.displayLarge),
      displayMedium: plain(theme.displayMedium),
      displaySmall: plain(theme.displaySmall),
      headlineLarge: plain(theme.headlineLarge),
      headlineMedium: plain(theme.headlineMedium),
      headlineSmall: plain(theme.headlineSmall),
      titleLarge: plain(theme.titleLarge),
      titleMedium: plain(theme.titleMedium),
      titleSmall: plain(theme.titleSmall),
      bodyLarge: plain(theme.bodyLarge),
      bodyMedium: plain(theme.bodyMedium)?.copyWith(height: 1.4),
      bodySmall: plain(theme.bodySmall),
      labelLarge: plain(theme.labelLarge),
      labelMedium: plain(theme.labelMedium),
      labelSmall: plain(theme.labelSmall),
    );
  }

  static ThemeData _buildTheme(ColorScheme colorScheme, WhisperColors c) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      // Use one family for Chinese and Latin text so CJK glyphs do not mix
      // weights and metrics through per-character system fallback.
      fontFamily: defaultTargetPlatform == TargetPlatform.windows
          ? AppTypography.windowsFontFamily
          : null,
      fontFamilyFallback: defaultTargetPlatform == TargetPlatform.windows
          ? const <String>[
              'Microsoft YaHei UI',
              'Microsoft YaHei',
              'Segoe UI',
              'Segoe UI Emoji',
            ]
          : null,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: WhisperDesktopPageTransitionsBuilder(),
          TargetPlatform.windows: WhisperDesktopPageTransitionsBuilder(),
          TargetPlatform.linux: WhisperDesktopPageTransitionsBuilder(),
          TargetPlatform.fuchsia: ZoomPageTransitionsBuilder(),
        },
      ),
      scaffoldBackgroundColor: colorScheme.surface,
      cardColor: colorScheme.surface,
      dividerColor: colorScheme.outlineVariant,
      cupertinoOverrideTheme: CupertinoThemeData(
        brightness: colorScheme.brightness,
        primaryColor: colorScheme.primary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.accent,
        selectionColor: colorScheme.brightness == Brightness.dark
            ? Radix.blueDarkA5
            : Radix.blueA5,
        selectionHandleColor: c.accent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.fill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.fill,
        selectedColor: colorScheme.primary.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: TextStyle(color: colorScheme.onSurface),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: c.raised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: c.sep),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        iconColor: colorScheme.onSurface,
      ),
    );

    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[c],
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontSize: 22,
          height: 28 / 22,
          letterSpacing: 0,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      textTheme: _textTheme(
        base.textTheme.apply(
          bodyColor: colorScheme.onSurface,
          displayColor: colorScheme.onSurface,
        ),
      ),
    );
  }
}
