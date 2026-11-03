import 'package:whisper/theme/whisper_window.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_motion.dart';
import 'package:whisper/widget/frosted_modal_route.dart';

const Duration whisperDialogEnterDuration = WhisperMotion.dialogEnter;
const Duration whisperDialogExitDuration = WhisperMotion.dialogExit;

Future<T?> showWhisperDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  bool useSafeArea = true,
  bool blurBackground = true,
  RouteSettings? routeSettings,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);

  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    WhisperFrostedPageRoute<T>(
      barrierBlurSigma: 0,
      settings: routeSettings,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: context.wc.scrim,
      transitionDuration: reduceMotion
          ? Duration.zero
          : whisperDialogEnterDuration,
      reverseTransitionDuration: reduceMotion
          ? Duration.zero
          : whisperDialogExitDuration,
      pageBuilder: (dialogContext, animation, secondaryAnimation) => useSafeArea
          ? SafeArea(child: builder(dialogContext))
          : builder(dialogContext),
      transitionsBuilder:
          (dialogContext, animation, secondaryAnimation, child) {
            if (reduceMotion) {
              return child;
            }
            return _DialogMotion(animation: animation, child: child);
          },
    ),
  );
}

class _DialogMotion extends StatefulWidget {
  const _DialogMotion({required this.animation, required this.child});
  final Animation<double> animation;
  final Widget child;

  @override
  State<_DialogMotion> createState() => _DialogMotionState();
}

class _DialogMotionState extends State<_DialogMotion> {
  late final CurvedAnimation _scale = CurvedAnimation(
    parent: widget.animation,
    curve: WhisperMotion.spring,
    reverseCurve: Curves.easeInCubic,
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: widget.animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void dispose() {
    _scale.dispose();
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: ScaleTransition(
      scale: Tween<double>(begin: .95, end: 1).animate(_scale),
      child: widget.child,
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
    this.insetAnimationDuration = const Duration(milliseconds: 100),
    this.blurBackground = true,
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
  final Duration insetAnimationDuration;
  final bool blurBackground;

  /// `.sheet`: raised, 20 inside, left-aligned, actions at the end.
  Widget _buildNew(BuildContext context) {
    final c = context.wc;
    final touch = !isDesktop();
    final type = WhisperType(touch: touch);
    final title = this.title;
    final content = this.content;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: insetPadding.horizontal / 2,
        vertical: WhisperWindow.sheetGap / 2,
      ),
      insetAnimationDuration: insetAnimationDuration,
      backgroundColor: Colors.transparent,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.none,
      child: ConstrainedBox(
        constraints: constraints.copyWith(
          maxWidth: constraints.maxWidth.clamp(0, 380),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.raised,
            borderRadius: BorderRadius.circular(WhisperRadius.l),
            boxShadow: WhisperShadow.e3(Theme.of(context).brightness),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: type.head,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                    child: title,
                  ),
                if (content != null) ...[
                  if (title != null) const SizedBox(height: 14),
                  Flexible(
                    fit: FlexFit.loose,
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        fontSize: type.note,
                        height: 1.5,
                        color: c.ink2,
                      ),
                      child: content,
                    ),
                  ),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildNew(context);
  }
}

/// Shared layout for short confirmations and informational alerts.
class WhisperAlertDialog extends StatelessWidget {
  const WhisperAlertDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => WhisperGlassDialog(
    constraints: const BoxConstraints(maxWidth: 380, maxHeight: 620),
    title: Text(title),
    content: SingleChildScrollView(child: content),
    actions: actions,
  );
}

class WhisperGlassSurface extends StatelessWidget {
  const WhisperGlassSurface({
    super.key,
    required this.borderRadius,
    required this.child,
    this.shadowOffset = const Offset(0, 18),
    this.showTopHighlight = true,
    this.showShadow = true,
    this.neutral = false,
    this.blurBackground = true,
  });

  final BorderRadius borderRadius;
  final Widget child;
  final Offset shadowOffset;
  final bool showTopHighlight;
  final bool showShadow;
  final bool neutral;
  final bool blurBackground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = context.wc;
    final isDark = theme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final isDesktop = switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };
    final radius = borderRadius;
    final baseOpacity = highContrast || !blurBackground
        ? 0.98
        : isDark
        ? 0.84
        : 0.82;
    final surface = palette.raised.withValues(alpha: baseOpacity);
    final topTint = Color.alphaBlend(
      neutral
          ? (isDark ? Radix.whiteA1 : Radix.whiteA4)
          : colors.primary.withValues(alpha: isDark ? 0.08 : 0.045),
      surface,
    );
    final bottomTint = neutral
        ? surface
        : Color.alphaBlend(
            colors.secondary.withValues(alpha: isDark ? 0.035 : 0.02),
            surface,
          );
    final borderColor = isDark
        ? (highContrast ? Radix.whiteA5 : Radix.whiteA3)
        : highContrast
        ? Radix.white
        : Radix.whiteA11;
    final blurSigma = highContrast
        ? 0.0
        : isDesktop
        ? 24.0
        : 12.0;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: showShadow
            ? <BoxShadow>[
                BoxShadow(
                  color: (isDark ? Radix.blackA6 : Radix.blackA4),
                  blurRadius: isDesktop ? 42 : 28,
                  spreadRadius: -8,
                  offset: shadowOffset,
                ),
                BoxShadow(
                  color: neutral
                      ? (isDark ? Radix.blackA2 : Radix.blackA1)
                      : colors.primary.withValues(alpha: isDark ? 0.08 : 0.05),
                  blurRadius: 22,
                  spreadRadius: -12,
                  offset: const Offset(0, 4),
                ),
              ]
            : const <BoxShadow>[],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          enabled: blurBackground && !highContrast,
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: borderColor),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[topTint, surface, bottomTint],
                stops: const <double>[0, 0.46, 1],
              ),
            ),
            child: Stack(
              children: <Widget>[
                if (showTopHighlight)
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
                              (isDark ? Radix.whiteA4 : Radix.whiteA10),
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
    return ShellButton(
      label: label,
      touch: !isDesktop(),
      onTap: onPressed,
      kind: destructive
          ? ShellButtonKind.danger
          : prominent
          ? ShellButtonKind.primary
          : ShellButtonKind.normal,
    );
  }
}
