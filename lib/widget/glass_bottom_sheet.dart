import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/radix_colors.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/frosted_modal_route.dart';
import 'package:whisper/widget/glass_dialog.dart';

const Duration whisperBottomSheetEnterDuration = Duration(milliseconds: 280);
const Duration whisperBottomSheetExitDuration = Duration(milliseconds: 200);

Future<T?> showWhisperGlassBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final isDark = Theme.of(context).brightness == Brightness.dark;

  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    WhisperFrostedPageRoute<T>(
      barrierBlurSigma: whisperModalBlurSigma(context),
      settings: routeSettings,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: isDark ? Radix.blackA7 : Radix.blackA4,
      transitionDuration: reduceMotion
          ? Duration.zero
          : whisperBottomSheetEnterDuration,
      reverseTransitionDuration: reduceMotion
          ? Duration.zero
          : whisperBottomSheetExitDuration,
      pageBuilder: (sheetContext, animation, secondaryAnimation) => Align(
        alignment: Alignment.bottomCenter,
        child: builder(sheetContext),
      ),
      transitionsBuilder: (sheetContext, animation, secondaryAnimation, child) {
        if (reduceMotion) {
          return child;
        }
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: Tween<double>(begin: 0.78, end: 1).animate(curved),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}

Future<T?> showWhisperModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool? showDragHandle,
  Color? backgroundColor,
  BoxConstraints? constraints,
  ShapeBorder? shape,
  AnimationStyle? sheetAnimationStyle,
}) {
  final navigator = Navigator.of(context);
  final localizations = MaterialLocalizations.of(context);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return navigator.push<T>(
    WhisperFrostedBottomSheetRoute<T>(
      builder: builder,
      barrierBlurSigma: whisperModalBlurSigma(context),
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
      modalBarrierColor: isDark ? Radix.blackA7 : Radix.blackA4,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      backgroundColor: backgroundColor,
      constraints: constraints,
      shape: shape,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : sheetAnimationStyle,
    ),
  );
}

class WhisperGlassActionSheet extends StatelessWidget {
  const WhisperGlassActionSheet({
    super.key,
    this.title,
    required this.actions,
    required this.cancelButton,
    this.maxWidth = 840,
    this.desktopWidthFactor = 0.82,
  });

  final Widget? title;
  final List<Widget> actions;
  final Widget cancelButton;
  final double maxWidth;
  final double desktopWidthFactor;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final theme = Theme.of(context);
    final palette = context.wc;
    final isDark = theme.brightness == Brightness.dark;
    final isCompact =
        mediaQuery.size.width < 600 ||
        switch (theme.platform) {
          TargetPlatform.android || TargetPlatform.iOS => true,
          _ => false,
        };
    final dividerColor = palette.sep.withValues(alpha: isDark ? 0.70 : 0.86);
    final radius = BorderRadius.circular(14);
    final safePadding = mediaQuery.padding;
    // Leave room beyond the gesture area for devices with large screen corners.
    final outerPadding = isCompact
        ? EdgeInsets.fromLTRB(
            safePadding.left + 16,
            safePadding.top + 8,
            safePadding.right + 16,
            math.max(
              24,
              math.max(safePadding.bottom, mediaQuery.viewInsets.bottom) + 12,
            ),
          )
        : EdgeInsets.only(bottom: safePadding.bottom + 8);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = isCompact
            ? math.min(
                constraints.maxWidth - outerPadding.horizontal,
                mediaQuery.size.shortestSide - 32,
              )
            : math.min(maxWidth, constraints.maxWidth * desktopWidthFactor);
        return Padding(
          padding: outerPadding,
          child: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Flexible(
                    fit: FlexFit.loose,
                    child: WhisperGlassSurface(
                      key: const ValueKey<String>(
                        'whisper-glass-action-sheet-main',
                      ),
                      borderRadius: radius,
                      shadowOffset: const Offset(0, 10),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (title != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 13.5,
                                ),
                                child: DefaultTextStyle.merge(
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: palette.ink2,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  child: Center(child: title),
                                ),
                              ),
                            if (title != null && actions.isNotEmpty)
                              SizedBox(
                                height: 0.75,
                                child: ColoredBox(color: dividerColor),
                              ),
                            for (
                              var index = 0;
                              index < actions.length;
                              index += 1
                            ) ...<Widget>[
                              if (index > 0)
                                SizedBox(
                                  height: 0.75,
                                  child: ColoredBox(color: dividerColor),
                                ),
                              actions[index],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  WhisperGlassSurface(
                    key: const ValueKey<String>(
                      'whisper-glass-action-sheet-cancel',
                    ),
                    borderRadius: radius,
                    shadowOffset: const Offset(0, 8),
                    child: cancelButton,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class WhisperGlassActionSheetAction extends StatelessWidget {
  const WhisperGlassActionSheetAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.defaultAction = false,
    this.icon,
  });

  final String label;
  final VoidCallback onPressed;
  final bool destructive;
  final bool defaultAction;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = context.wc;
    final isDark = theme.brightness == Brightness.dark;
    final foreground = destructive ? palette.bad : colors.onSurface;

    return SizedBox(
      width: double.infinity,
      child: Semantics(
        button: true,
        child: TextButton(
          onPressed: onPressed,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 57)),
            padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(
                horizontal: icon == null ? 10 : 18,
                vertical: 8,
              ),
            ),
            shape: const WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(),
            ),
            foregroundColor: WidgetStatePropertyAll<Color>(foreground),
            backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.pressed)) {
                return colors.onSurface.withValues(alpha: isDark ? 0.20 : 0.12);
              }
              if (states.contains(WidgetState.hovered)) {
                return colors.onSurface.withValues(alpha: isDark ? 0.13 : 0.07);
              }
              if (states.contains(WidgetState.focused)) {
                return colors.primary.withValues(alpha: isDark ? 0.18 : 0.10);
              }
              return Colors.transparent;
            }),
            overlayColor: const WidgetStatePropertyAll<Color>(
              Colors.transparent,
            ),
            splashFactory: NoSplash.splashFactory,
            animationDuration: const Duration(milliseconds: 120),
            textStyle: WidgetStatePropertyAll<TextStyle>(
              TextStyle(
                fontSize: icon == null ? 21 : 17,
                fontWeight: defaultAction ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: icon == null
              ? Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                )
              : Row(
                  children: [
                    Expanded(child: Text(label)),
                    const SizedBox(width: 16),
                    Icon(icon, size: 21),
                  ],
                ),
        ),
      ),
    );
  }
}

class WhisperGlassMenuOption<T> {
  const WhisperGlassMenuOption({required this.value, required this.label});

  final T value;
  final String label;
}

class WhisperGlassMenuButton<T> extends StatelessWidget {
  const WhisperGlassMenuButton({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
    this.minimumMenuWidth = 132,
  });

  final T value;
  final List<WhisperGlassMenuOption<T>> options;
  final ValueChanged<T> onChanged;
  final bool enabled;
  final double minimumMenuWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = context.wc;
    final isDark = theme.brightness == Brightness.dark;
    final currentLabel = options
        .where((option) => option.value == value)
        .map((option) => option.label)
        .firstOrNull;
    final menuRadius = BorderRadius.circular(12);

    return MenuAnchor(
      useRootOverlay: true,
      consumeOutsideTap: true,
      clipBehavior: Clip.none,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.zero,
        ),
        minimumSize: WidgetStatePropertyAll<Size>(Size(minimumMenuWidth, 0)),
        backgroundColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        elevation: const WidgetStatePropertyAll<double>(0),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: menuRadius),
        ),
        visualDensity: VisualDensity.compact,
      ),
      menuChildren: <Widget>[
        WhisperGlassSurface(
          borderRadius: menuRadius,
          shadowOffset: const Offset(0, 8),
          neutral: true,
          child: SizedBox(
            width: minimumMenuWidth,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (var index = 0; index < options.length; index += 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      child: MenuItemButton(
                        onPressed: enabled
                            ? () => onChanged(options[index].value)
                            : null,
                        closeOnActivate: true,
                        leadingIcon: options[index].value == value
                            ? Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: colors.primary,
                              )
                            : const SizedBox(width: 16),
                        style: ButtonStyle(
                          minimumSize: WidgetStatePropertyAll<Size>(
                            Size(minimumMenuWidth - 10, 34),
                          ),
                          padding:
                              const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                                EdgeInsets.symmetric(horizontal: 8),
                              ),
                          foregroundColor: WidgetStatePropertyAll<Color>(
                            colors.onSurface,
                          ),
                          textStyle: WidgetStatePropertyAll<TextStyle>(
                            theme.textTheme.bodyMedium!.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          backgroundColor:
                              WidgetStateProperty.resolveWith<Color>((states) {
                                if (states.contains(WidgetState.pressed)) {
                                  return colors.onSurface.withValues(
                                    alpha: isDark ? 0.17 : 0.09,
                                  );
                                }
                                if (states.contains(WidgetState.hovered) ||
                                    states.contains(WidgetState.focused)) {
                                  return colors.onSurface.withValues(
                                    alpha: isDark ? 0.12 : 0.06,
                                  );
                                }
                                if (options[index].value == value) {
                                  return colors.primary.withValues(
                                    alpha: isDark ? 0.16 : 0.075,
                                  );
                                }
                                return Colors.transparent;
                              }),
                          overlayColor: const WidgetStatePropertyAll<Color>(
                            Colors.transparent,
                          ),
                          shape: WidgetStatePropertyAll<OutlinedBorder>(
                            RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(7),
                            ),
                          ),
                          animationDuration: const Duration(milliseconds: 100),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(options[index].label),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
      builder: (context, controller, child) {
        return TextButton(
          onPressed: enabled
              ? () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                }
              : null,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 32)),
            padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            ),
            foregroundColor: WidgetStatePropertyAll<Color>(
              enabled ? colors.onSurface : palette.ink2,
            ),
            backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.pressed)) {
                return colors.onSurface.withValues(alpha: isDark ? 0.17 : 0.09);
              }
              if (states.contains(WidgetState.hovered) || controller.isOpen) {
                return colors.onSurface.withValues(
                  alpha: isDark ? 0.12 : 0.065,
                );
              }
              return palette.fill.withValues(alpha: isDark ? 0.42 : 0.50);
            }),
            overlayColor: const WidgetStatePropertyAll<Color>(
              Colors.transparent,
            ),
            shape: WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            ),
            textStyle: WidgetStatePropertyAll<TextStyle>(
              theme.textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w500),
            ),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(currentLabel ?? ''),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: controller.isOpen ? 0.5 : 0,
                duration: const Duration(milliseconds: 120),
                child: const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
              ),
            ],
          ),
        );
      },
    );
  }
}
