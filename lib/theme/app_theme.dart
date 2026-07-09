import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

abstract final class WhisperUi {
  static const radiusSmall = 4.0;
  static const radiusMedium = 6.0;
  static const radiusLarge = 8.0;
  static const minInteractiveSize = 44.0;
  static const settingsMaxWidth = 760.0;
  static const compactWindowBreakpoint = 760.0;
  static const expandedWindowBreakpoint = 1100.0;
}

class WhisperPalette extends ThemeExtension<WhisperPalette> {
  const WhisperPalette({
    required this.connected,
    required this.trusted,
    required this.warning,
    required this.danger,
    required this.surfaceMuted,
    required this.surfaceElevated,
    required this.surfaceCanvas,
    required this.borderSubtle,
    required this.textMuted,
    required this.messageIncoming,
    required this.messageOutgoing,
  });

  final Color connected;
  final Color trusted;
  final Color warning;
  final Color danger;
  final Color surfaceMuted;
  final Color surfaceElevated;
  final Color surfaceCanvas;
  final Color borderSubtle;
  final Color textMuted;
  final Color messageIncoming;
  final Color messageOutgoing;

  @override
  WhisperPalette copyWith({
    Color? connected,
    Color? trusted,
    Color? warning,
    Color? danger,
    Color? surfaceMuted,
    Color? surfaceElevated,
    Color? surfaceCanvas,
    Color? borderSubtle,
    Color? textMuted,
    Color? messageIncoming,
    Color? messageOutgoing,
  }) {
    return WhisperPalette(
      connected: connected ?? this.connected,
      trusted: trusted ?? this.trusted,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      surfaceCanvas: surfaceCanvas ?? this.surfaceCanvas,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      textMuted: textMuted ?? this.textMuted,
      messageIncoming: messageIncoming ?? this.messageIncoming,
      messageOutgoing: messageOutgoing ?? this.messageOutgoing,
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
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceCanvas: Color.lerp(surfaceCanvas, other.surfaceCanvas, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      messageIncoming: Color.lerp(messageIncoming, other.messageIncoming, t)!,
      messageOutgoing: Color.lerp(messageOutgoing, other.messageOutgoing, t)!,
    );
  }
}

class AppTheme {
  const AppTheme._();

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF2563EB),
    onPrimary: Colors.white,
    secondary: Color(0xFF5F6875),
    onSecondary: Colors.white,
    error: Color(0xFFC93838),
    onError: Colors.white,
    surface: Colors.white,
    onSurface: Color(0xFF171A1F),
    tertiary: Color(0xFFB96A05),
    onTertiary: Color(0xFF171A1F),
    outline: Color(0xFF707985),
    outlineVariant: Color(0xFFDDE1E6),
    surfaceTint: Colors.transparent,
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF7CA7FF),
    onPrimary: Color(0xFF07152E),
    secondary: Color(0xFFA1A9B5),
    onSecondary: Color(0xFF111318),
    error: Color(0xFFFF8A8A),
    onError: Color(0xFF3F0808),
    surface: Color(0xFF111318),
    onSurface: Color(0xFFF2F4F7),
    tertiary: Color(0xFFF2B45F),
    onTertiary: Color(0xFF2B1900),
    outline: Color(0xFF929BA7),
    outlineVariant: Color(0xFF303640),
    surfaceTint: Colors.transparent,
  );

  static const _lightPalette = WhisperPalette(
    connected: Color(0xFF1D6FD8),
    trusted: Color(0xFF18864B),
    warning: Color(0xFFB96A05),
    danger: Color(0xFFC93838),
    surfaceMuted: Color(0xFFEEF0F3),
    surfaceElevated: Colors.white,
    surfaceCanvas: Color(0xFFF6F7F9),
    borderSubtle: Color(0xFFDDE1E6),
    textMuted: Color(0xFF5F6875),
    messageIncoming: Color(0xFFF6F7F9),
    messageOutgoing: Color(0xFFECF2FF),
  );

  static const _darkPalette = WhisperPalette(
    connected: Color(0xFF77A9FF),
    trusted: Color(0xFF56C987),
    warning: Color(0xFFF2B45F),
    danger: Color(0xFFFF8A8A),
    surfaceMuted: Color(0xFF1D2127),
    surfaceElevated: Color(0xFF171A20),
    surfaceCanvas: Color(0xFF0B0D10),
    borderSubtle: Color(0xFF303640),
    textMuted: Color(0xFFA1A9B5),
    messageIncoming: Color(0xFF171A20),
    messageOutgoing: Color(0xFF1A2740),
  );

  static WhisperPalette fallbackPalette(Brightness brightness) {
    return brightness == Brightness.dark ? _darkPalette : _lightPalette;
  }

  static final ThemeData lightTheme = _buildTheme(_lightScheme, _lightPalette);

  static final ThemeData darkTheme = _buildTheme(_darkScheme, _darkPalette);

  static ThemeData _buildTheme(
      ColorScheme colorScheme, WhisperPalette palette) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
          TargetPlatform.fuchsia: ZoomPageTransitionsBuilder(),
        },
      ),
      scaffoldBackgroundColor: colorScheme.surface,
      cardColor: colorScheme.surface,
      dividerColor: palette.borderSubtle,
      materialTapTargetSize: MaterialTapTargetSize.padded,
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
        cursorColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.24),
        selectionHandleColor: colorScheme.primary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceMuted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
          borderSide: BorderSide(color: palette.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
          borderSide: BorderSide(color: palette.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: palette.surfaceMuted,
        selectedColor: colorScheme.primary.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WhisperUi.radiusMedium),
        ),
        labelStyle: TextStyle(color: colorScheme.onSurface),
        side: BorderSide(color: palette.borderSubtle),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: palette.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
          side: BorderSide(color: palette.borderSubtle),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WhisperUi.radiusMedium),
        ),
        iconColor: colorScheme.onSurface,
      ),
      dialogTheme: DialogThemeData(
        elevation: 3,
        backgroundColor: palette.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WhisperUi.radiusLarge),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: _buttonStyle(WhisperUi.radiusLarge),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _buttonStyle(WhisperUi.radiusMedium),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: _buttonStyle(WhisperUi.radiusMedium),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: _buttonStyle(WhisperUi.radiusMedium),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _buttonStyle(WhisperUi.radiusMedium),
      ),
    );

    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[palette],
      textTheme: _systemTextTheme(base.textTheme, colorScheme.onSurface),
    );
  }

  static ButtonStyle _buttonStyle(double radius) {
    return ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(
        Size.square(WhisperUi.minInteractiveSize),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
    );
  }

  static TextTheme _systemTextTheme(TextTheme source, Color color) {
    TextStyle? style(TextStyle? value) =>
        value?.copyWith(color: color, letterSpacing: 0);

    return source.copyWith(
      displayLarge: style(source.displayLarge),
      displayMedium: style(source.displayMedium),
      displaySmall: style(source.displaySmall),
      headlineLarge: style(source.headlineLarge),
      headlineMedium: style(source.headlineMedium),
      headlineSmall: style(source.headlineSmall),
      titleLarge: style(source.titleLarge),
      titleMedium: style(source.titleMedium),
      titleSmall: style(source.titleSmall),
      bodyLarge: style(source.bodyLarge),
      bodyMedium: style(source.bodyMedium),
      bodySmall: style(source.bodySmall),
      labelLarge: style(source.labelLarge),
      labelMedium: style(source.labelMedium),
      labelSmall: style(source.labelSmall),
    );
  }
}

extension WhisperPaletteX on BuildContext {
  WhisperPalette get whisperPalette =>
      Theme.of(this).extension<WhisperPalette>() ??
      AppTheme.fallbackPalette(Theme.of(this).brightness);
}
