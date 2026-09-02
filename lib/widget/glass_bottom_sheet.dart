import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';
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
    PageRouteBuilder<T>(
      settings: routeSettings,
      opaque: false,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: isDark
          ? Colors.black.withValues(alpha: 0.46)
          : const Color(0xFF0F172A).withValues(alpha: 0.22),
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

class WhisperGlassActionSheet extends StatelessWidget {
  const WhisperGlassActionSheet({
    super.key,
    required this.title,
    required this.actions,
    required this.cancelButton,
    this.maxWidth = 840,
    this.desktopWidthFactor = 0.82,
  });

  final Widget title;
  final List<Widget> actions;
  final Widget cancelButton;
  final double maxWidth;
  final double desktopWidthFactor;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    final isDark = theme.brightness == Brightness.dark;
    final isCompact =
        mediaQuery.size.width < 600 ||
        switch (theme.platform) {
          TargetPlatform.android || TargetPlatform.iOS => true,
          _ => false,
        };
    final dividerColor = palette.borderSubtle.withValues(
      alpha: isDark ? 0.70 : 0.86,
    );
    final radius = BorderRadius.circular(14);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = isCompact
            ? constraints.maxWidth
            : math.min(maxWidth, constraints.maxWidth * desktopWidthFactor);
        return Padding(
          padding: EdgeInsets.only(
            bottom: mediaQuery.padding.bottom + (isCompact ? 0 : 8),
          ),
          child: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  WhisperGlassSurface(
                    key: const ValueKey<String>(
                      'whisper-glass-action-sheet-main',
                    ),
                    borderRadius: radius,
                    shadowOffset: const Offset(0, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 13.5,
                          ),
                          child: DefaultTextStyle.merge(
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.textMuted,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            child: Center(child: title),
                          ),
                        ),
                        if (actions.isNotEmpty)
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
  });

  final String label;
  final VoidCallback onPressed;
  final bool destructive;
  final bool defaultAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = context.whisperPalette;
    final isDark = theme.brightness == Brightness.dark;
    final foreground = destructive ? palette.danger : colors.onSurface;

    return SizedBox(
      width: double.infinity,
      child: Semantics(
        button: true,
        child: TextButton(
          onPressed: onPressed,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 57)),
            padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
              EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                fontSize: 21,
                fontWeight: defaultAction ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

class WhisperGlassBottomSheet extends StatelessWidget {
  const WhisperGlassBottomSheet({
    super.key,
    required this.title,
    required this.content,
    this.actions = const <Widget>[],
    this.maxSheetWidth = 720,
    this.maxContentWidth = 620,
    this.contentPadding = const EdgeInsets.fromLTRB(20, 8, 20, 18),
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final double maxSheetWidth;
  final double maxContentWidth;
  final EdgeInsets contentPadding;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * 0.88;
    final isMobilePlatform = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final connectsToSides =
            isMobilePlatform || constraints.maxWidth <= maxSheetWidth + 48;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
            child: Material(
              color: Colors.transparent,
              child: SizedBox(
                width: connectsToSides ? double.infinity : maxSheetWidth,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: WhisperGlassSurface(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                    shadowOffset: const Offset(0, -10),
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: mediaQuery.padding.bottom,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          const SizedBox(height: 10),
                          Center(
                            child: Container(
                              width: 36,
                              height: 5,
                              decoration: BoxDecoration(
                                color: context.whisperPalette.textMuted
                                    .withValues(alpha: 0.34),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 13, 20, 8),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: maxContentWidth,
                                ),
                                child: DefaultTextStyle.merge(
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                  child: title,
                                ),
                              ),
                            ),
                          ),
                          Flexible(
                            fit: FlexFit.loose,
                            child: SingleChildScrollView(
                              padding: contentPadding,
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: maxContentWidth,
                                  ),
                                  child: content,
                                ),
                              ),
                            ),
                          ),
                          if (actions.isNotEmpty)
                            WhisperDialogActionBar(actions: actions),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
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
    final palette = context.whisperPalette;
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
              enabled ? colors.onSurface : palette.textMuted,
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
              return palette.surfaceMuted.withValues(
                alpha: isDark ? 0.42 : 0.50,
              );
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

class WhisperGlassSelectionMenu extends StatelessWidget {
  const WhisperGlassSelectionMenu({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = context.whisperPalette;
    final isDark = theme.brightness == Brightness.dark;
    final dividerColor = palette.borderSubtle.withValues(
      alpha: isDark ? 0.62 : 0.72,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.82),
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color.alphaBlend(
              colors.primary.withValues(alpha: isDark ? 0.045 : 0.025),
              palette.surfaceMuted.withValues(alpha: isDark ? 0.52 : 0.58),
            ),
            palette.surfaceMuted.withValues(alpha: isDark ? 0.42 : 0.48),
          ],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var index = 0; index < children.length; index += 1) ...[
              if (index > 0)
                SizedBox(height: 0.75, child: ColoredBox(color: dividerColor)),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}

class WhisperGlassSelectionTile extends StatelessWidget {
  const WhisperGlassSelectionTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.leading,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = selected ? colors.primary : colors.onSurface;

    return Semantics(
      button: true,
      selected: selected,
      child: TextButton(
        onPressed: onPressed,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 54)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(),
          ),
          backgroundColor: const WidgetStatePropertyAll<Color>(
            Colors.transparent,
          ),
          overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
            if (states.contains(WidgetState.pressed)) {
              return Color.lerp(colors.primary, colors.onSurface, 0.20)!;
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return colors.primary;
            }
            return foreground;
          }),
          textStyle: WidgetStateProperty.resolveWith<TextStyle>((states) {
            return theme.textTheme.bodyLarge!.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              decoration: states.contains(WidgetState.focused)
                  ? TextDecoration.underline
                  : TextDecoration.none,
              decorationColor: colors.primary.withValues(alpha: 0.72),
              decorationThickness: 1.4,
            );
          }),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: SizedBox(
          width: double.infinity,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              if (leading != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconTheme.merge(
                    data: const IconThemeData(size: 20),
                    child: leading!,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 160),
                  child: selected
                      ? Icon(
                          Icons.check_rounded,
                          key: const ValueKey<bool>(true),
                          color: colors.primary,
                          size: 22,
                        )
                      : const SizedBox(
                          key: ValueKey<bool>(false),
                          width: 22,
                          height: 22,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
