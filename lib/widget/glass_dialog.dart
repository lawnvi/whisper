import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';

const Duration whisperDialogEnterDuration = Duration(milliseconds: 220);
const Duration whisperDialogExitDuration = Duration(milliseconds: 150);

Future<T?> showWhisperDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final brightness = Theme.of(context).brightness;

  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    PageRouteBuilder<T>(
      settings: routeSettings,
      opaque: false,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: brightness == Brightness.dark
          ? Colors.black.withValues(alpha: 0.50)
          : const Color(0xFF0F172A).withValues(alpha: 0.24),
      transitionDuration: reduceMotion
          ? Duration.zero
          : whisperDialogEnterDuration,
      reverseTransitionDuration: reduceMotion
          ? Duration.zero
          : whisperDialogExitDuration,
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          SafeArea(child: builder(dialogContext)),
      transitionsBuilder:
          (dialogContext, animation, secondaryAnimation, child) {
            if (reduceMotion) {
              return child;
            }
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
                child: child,
              ),
            );
          },
    ),
  );
}

class WhisperGlassDialog extends StatelessWidget {
  const WhisperGlassDialog({
    super.key,
    this.title,
    this.content,
    this.actions = const <Widget>[],
    this.constraints = const BoxConstraints(
      minWidth: 280,
      maxWidth: 480,
      maxHeight: 720,
    ),
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 24,
      vertical: 24,
    ),
    this.titlePadding = const EdgeInsets.fromLTRB(24, 24, 24, 12),
    this.contentPadding = const EdgeInsets.fromLTRB(24, 0, 24, 8),
    this.actionsPadding = const EdgeInsets.only(top: 12),
    this.borderRadius = 26,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget> actions;
  final BoxConstraints constraints;
  final EdgeInsets insetPadding;
  final EdgeInsets titlePadding;
  final EdgeInsets contentPadding;
  final EdgeInsets actionsPadding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: insetPadding,
      backgroundColor: Colors.transparent,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.none,
      child: ConstrainedBox(
        constraints: constraints,
        child: WhisperGlassSurface(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (title != null) Padding(padding: titlePadding, child: title),
              if (content != null)
                Flexible(
                  fit: FlexFit.loose,
                  child: Padding(padding: contentPadding, child: content),
                ),
              if (actions.isNotEmpty)
                Padding(
                  padding: actionsPadding,
                  child: WhisperDialogActionBar(actions: actions),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class WhisperGlassSurface extends StatelessWidget {
  const WhisperGlassSurface({
    super.key,
    required this.borderRadius,
    required this.child,
    this.shadowOffset = const Offset(0, 18),
  });

  final BorderRadius borderRadius;
  final Widget child;
  final Offset shadowOffset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = context.whisperPalette;
    final isDark = theme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final isDesktop = switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };
    final radius = borderRadius;
    final baseOpacity = highContrast
        ? 0.98
        : isDark
        ? 0.84
        : 0.82;
    final surface = palette.surfaceElevated.withValues(alpha: baseOpacity);
    final topTint = Color.alphaBlend(
      colors.primary.withValues(alpha: isDark ? 0.08 : 0.045),
      surface,
    );
    final borderColor = isDark
        ? Colors.white.withValues(alpha: highContrast ? 0.32 : 0.16)
        : const Color(0xFFFFFFFF).withValues(alpha: highContrast ? 1 : 0.88);
    final blurSigma = highContrast
        ? 0.0
        : isDesktop
        ? 24.0
        : 12.0;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.44 : 0.18),
            blurRadius: isDesktop ? 42 : 28,
            spreadRadius: -8,
            offset: shadowOffset,
          ),
          BoxShadow(
            color: colors.primary.withValues(alpha: isDark ? 0.08 : 0.05),
            blurRadius: 22,
            spreadRadius: -12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: borderColor),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  topTint,
                  surface,
                  Color.alphaBlend(
                    colors.secondary.withValues(alpha: isDark ? 0.035 : 0.02),
                    surface,
                  ),
                ],
                stops: const <double>[0, 0.46, 1],
              ),
            ),
            child: Stack(
              children: <Widget>[
                Positioned(
                  top: 0,
                  left: 16,
                  right: 16,
                  child: IgnorePointer(
                    child: Container(
                      height: 1,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: <Color>[
                            Colors.transparent,
                            Colors.white.withValues(
                              alpha: isDark ? 0.22 : 0.78,
                            ),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WhisperDialogActionBar extends StatelessWidget {
  const WhisperDialogActionBar({super.key, required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final dividerColor = context.whisperPalette.borderSubtle.withValues(
      alpha: Theme.of(context).brightness == Brightness.dark ? 0.72 : 0.82,
    );
    final topBorder = BorderSide(color: dividerColor, width: 0.75);

    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: topBorder)),
      child: actions.length <= 2
          ? SizedBox(
              height: 52,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var index = 0; index < actions.length; index += 1) ...[
                    if (index > 0)
                      SizedBox(
                        width: 0.75,
                        child: ColoredBox(color: dividerColor),
                      ),
                    Expanded(child: actions[index]),
                  ],
                ],
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var index = 0; index < actions.length; index += 1) ...[
                  if (index > 0)
                    SizedBox(
                      height: 0.75,
                      child: ColoredBox(color: dividerColor),
                    ),
                  SizedBox(height: 52, child: actions[index]),
                ],
              ],
            ),
    );
  }
}

class WhisperDialogButton extends StatelessWidget {
  const WhisperDialogButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.prominent = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool prominent;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = context.whisperPalette;
    final isDark = theme.brightness == Brightness.dark;
    final foreground = destructive ? palette.danger : colors.primary;
    final child = Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 18),
          const SizedBox(width: 7),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
    return TextButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 52)),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        ),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(),
        ),
        foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.disabled)) {
            return colors.onSurface.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.pressed)) {
            return Color.lerp(foreground, colors.onSurface, 0.16);
          }
          return foreground;
        }),
        backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.disabled)) {
            return Colors.transparent;
          }
          if (states.contains(WidgetState.pressed)) {
            return foreground.withValues(alpha: isDark ? 0.20 : 0.14);
          }
          if (states.contains(WidgetState.hovered)) {
            return foreground.withValues(alpha: isDark ? 0.14 : 0.08);
          }
          if (states.contains(WidgetState.focused)) {
            return foreground.withValues(alpha: isDark ? 0.16 : 0.10);
          }
          return Colors.transparent;
        }),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        animationDuration: const Duration(milliseconds: 120),
        textStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(fontWeight: prominent ? FontWeight.w600 : FontWeight.w400),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: child,
    );
  }
}
