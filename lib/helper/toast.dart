import 'dart:async';

import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/theme/app_theme.dart';

enum ToastUnavailableReason { noOverlay, renderFailure }

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

const _defaultToastDuration = Duration(seconds: 3);

void showAppToast(String message, {Duration? duration}) {
  unawaited(_showAppToast(message, duration: duration));
}

Future<void> _showAppToast(String message, {Duration? duration}) async {
  final overlayState = appNavigatorKey.currentState?.overlay;
  if (overlayState == null) {
    privacyLog.event(
      PrivacyEvent.toastUnavailable,
      <PrivacyField, Object>{
        PrivacyField.reason: ToastUnavailableReason.noOverlay,
      },
    );
    return;
  }

  try {
    toastification
      ..dismissAll(delayForAnimation: false)
      ..showCustom(
        overlayState: overlayState,
        alignment: Alignment.bottomCenter,
        autoCloseDuration: duration ?? _defaultToastDuration,
        animationDuration: const Duration(milliseconds: 220),
        animationBuilder: _buildToastAnimation,
        builder: (context, item) => _AppToastView(
          message: message,
          onDismiss: () => toastification.dismiss(item),
        ),
      );
  } catch (error) {
    privacyLog.event(
      PrivacyEvent.toastUnavailable,
      <PrivacyField, Object>{
        PrivacyField.reason: ToastUnavailableReason.renderFailure,
        PrivacyField.errorType: privacyLog.errorType(error),
      },
    );
  }
}

Widget _buildToastAnimation(
  BuildContext context,
  Animation<double> animation,
  Alignment alignment,
  Widget child,
) {
  final curvedAnimation = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  return FadeTransition(
    opacity: curvedAnimation,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.12),
        end: Offset.zero,
      ).animate(curvedAnimation),
      child: child,
    ),
  );
}

class _AppToastView extends StatelessWidget {
  const _AppToastView({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final isDark = theme.brightness == Brightness.dark;
    final backgroundColor = Color.alphaBlend(
      colorScheme.primary.withValues(alpha: isDark ? 0.10 : 0.04),
      palette.surfaceElevated,
    );
    final borderColor = isDark
        ? colorScheme.primary.withValues(alpha: 0.22)
        : palette.borderSubtle;
    final shadowColor = Colors.black.withValues(alpha: isDark ? 0.42 : 0.12);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: message,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: borderColor),
                boxShadow: [
                  BoxShadow(
                    color: shadowColor,
                    blurRadius: isDark ? 24 : 18,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 28,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withValues(
                              alpha: isDark ? 0.20 : 0.10,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.info_outline_rounded,
                            size: 17,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          message,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                                height: 1.35,
                              ) ??
                              TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                height: 1.35,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
