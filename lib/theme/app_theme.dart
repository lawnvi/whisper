import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class WhisperPalette extends ThemeExtension<WhisperPalette> {
  const WhisperPalette({
    required this.connected,
    required this.trusted,
    required this.warning,
    required this.danger,
    required this.surfaceMuted,
  });

  final Color connected;
  final Color trusted;
  final Color warning;
  final Color danger;
  final Color surfaceMuted;

  @override
  WhisperPalette copyWith({
    Color? connected,
    Color? trusted,
    Color? warning,
    Color? danger,
    Color? surfaceMuted,
  }) {
    return WhisperPalette(
      connected: connected ?? this.connected,
      trusted: trusted ?? this.trusted,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
    );
  }

  @override
  WhisperPalette lerp(ThemeExtension<WhisperPalette>? other, double t) {
    if (other is! WhisperPalette) {
      return this;
    }
    return WhisperPalette(
      connected: Color.lerp(connected, other.connected, t)!,
      trusted: Color.lerp(trusted, other.trusted, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
    );
  }
}

class AppTheme {
  const AppTheme._();

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF2563EB),
    onPrimary: Colors.white,
    secondary: Color(0xFF0EA5E9),
    onSecondary: Colors.white,
    error: Color(0xFFDC2626),
    onError: Colors.white,
    surface: Color(0xFFF8FAFC),
    onSurface: Color(0xFF0F172A),
    tertiary: Color(0xFFF59E0B),
    onTertiary: Colors.white,
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF60A5FA),
    onPrimary: Color(0xFF082F49),
    secondary: Color(0xFF38BDF8),
    onSecondary: Color(0xFF082F49),
    error: Color(0xFFF87171),
    onError: Color(0xFF450A0A),
    surface: Color(0xFF0F172A),
    onSurface: Color(0xFFE2E8F0),
    tertiary: Color(0xFFFBBF24),
    onTertiary: Color(0xFF451A03),
  );

  static final ThemeData lightTheme = _buildTheme(
      _lightScheme,
      const WhisperPalette(
        connected: Color(0xFF0284C7),
        trusted: Color(0xFF16A34A),
        warning: Color(0xFFD97706),
        danger: Color(0xFFDC2626),
        surfaceMuted: Color(0xFFE2E8F0),
      ));

  static final ThemeData darkTheme = _buildTheme(
      _darkScheme,
      const WhisperPalette(
        connected: Color(0xFF38BDF8),
        trusted: Color(0xFF4ADE80),
        warning: Color(0xFFFBBF24),
        danger: Color(0xFFF87171),
        surfaceMuted: Color(0xFF1E293B),
      ));

  static ThemeData _buildTheme(
      ColorScheme colorScheme, WhisperPalette palette) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
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
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceMuted,
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
        backgroundColor: palette.surfaceMuted,
        selectedColor: colorScheme.primary.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: TextStyle(color: colorScheme.onSurface),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        iconColor: colorScheme.onSurface,
      ),
    );

    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[palette],
      textTheme: base.textTheme.apply(
        bodyColor: colorScheme.onSurface,
        displayColor: colorScheme.onSurface,
      ),
    );
  }
}

extension WhisperPaletteX on BuildContext {
  WhisperPalette get whisperPalette =>
      Theme.of(this).extension<WhisperPalette>()!;
}
