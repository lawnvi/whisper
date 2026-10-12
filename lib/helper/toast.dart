import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/theme/app_theme.dart';

enum ToastUnavailableReason { noOverlay, renderFailure }

/// What a toast reports. It picks the leading icon and its colour, so a
/// failure never looks like a confirmation.
enum AppToastTone { info, success, warning, error }

/// A single follow-up the user can take straight from the toast.
class AppToastAction {
  const AppToastAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Give this to the [ToastificationWrapper] around the app. One toast shows at
/// a time: a newer one replaces whatever is up, including one raised earlier
/// in the same frame, which dismissing by hand would miss.
const appToastConfig = ToastificationConfig(maxToastLimit: 1);

/// Long enough to read [message] once: short confirmations leave quickly,
/// instructions stay, and a toast with an action waits for the tap.
@visibleForTesting
Duration appToastDurationFor(String message, {bool hasAction = false}) {
  final reading = 2400 + message.runes.length * 50;
  return Duration(milliseconds: reading.clamp(hasAction ? 5000 : 2600, 6000));
}

void showAppToast(
  String message, {
  AppToastTone tone = AppToastTone.info,
  AppToastAction? action,
  Duration? duration,
}) {
  final overlayState = appNavigatorKey.currentState?.overlay;
  if (overlayState == null) {
    privacyLog.event(PrivacyEvent.toastUnavailable, <PrivacyField, Object>{
      PrivacyField.reason: ToastUnavailableReason.noOverlay,
    });
    return;
  }

  try {
    toastification
      ..dismissAll(delayForAnimation: false)
      ..showCustom(
        overlayState: overlayState,
        alignment: Alignment.topCenter,
        autoCloseDuration:
            duration ?? appToastDurationFor(message, hasAction: action != null),
        animationDuration: const Duration(milliseconds: 240),
        animationBuilder: _buildToastAnimation,
        builder: (context, item) => _AppToastView(
          message: message,
          tone: tone,
          action: action,
          onDismiss: () => toastification.dismiss(item),
        ),
      );
  } catch (error) {
    privacyLog.event(PrivacyEvent.toastUnavailable, <PrivacyField, Object>{
      PrivacyField.reason: ToastUnavailableReason.renderFailure,
      PrivacyField.errorType: privacyLog.errorType(error),
    });
  }
}

Widget _buildToastAnimation(
  BuildContext context,
  Animation<double> animation,
  Alignment alignment,
  Widget child,
) {
  if (MediaQuery.disableAnimationsOf(context)) {
    return child;
  }
  final curvedAnimation = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  return FadeTransition(
    opacity: curvedAnimation,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, -0.35),
        end: Offset.zero,
      ).animate(curvedAnimation),
      child: child,
    ),
  );
}

class _AppToastView extends StatelessWidget {
  const _AppToastView({
    required this.message,
    required this.tone,
    required this.action,
    required this.onDismiss,
  });

  final String message;
  final AppToastTone tone;
  final AppToastAction? action;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final (icon, iconColor) = switch (tone) {
      AppToastTone.info => (Icons.info_rounded, colorScheme.primary),
      AppToastTone.success => (Icons.check_circle_rounded, palette.trusted),
      AppToastTone.warning => (Icons.warning_rounded, palette.warning),
      AppToastTone.error => (Icons.error_rounded, palette.danger),
    };
    final action = this.action;
    final isDark = theme.brightness == Brightness.dark;
    // A step lighter than the page in the dark theme, where the page itself
    // is black and a border alone would not lift the capsule off it.
    final surfaceColor = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            palette.surfaceElevated,
          )
        : palette.surfaceElevated;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : palette.borderSubtle;
    final shadowColor = isDark ? Colors.black : const Color(0xFF0F172A);

    // The package hands every toast a fixed-width slot and starts it at the
    // leading edge; fill the slot so the capsule can sit in its centre.
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        child: Center(
          child: Semantics(
            container: true,
            liveRegion: true,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: surfaceColor,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: borderColor),
                    boxShadow: [
                      BoxShadow(
                        color: shadowColor.withValues(
                          alpha: isDark ? 0.50 : 0.10,
                        ),
                        blurRadius: 24,
                        spreadRadius: -4,
                        offset: const Offset(0, 8),
                      ),
                      BoxShadow(
                        color: shadowColor.withValues(
                          alpha: isDark ? 0.30 : 0.04,
                        ),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(
                        14,
                        10,
                        action == null ? 18 : 6,
                        10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 18, color: iconColor),
                          const SizedBox(width: 9),
                          Flexible(
                            child: Text(
                              message,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  (theme.textTheme.bodyMedium ??
                                          const TextStyle(fontSize: 14))
                                      .copyWith(
                                        color: colorScheme.onSurface,
                                        fontWeight: FontWeight.w500,
                                        height: 1.35,
                                        letterSpacing: 0,
                                      ),
                            ),
                          ),
                          if (action != null) ...[
                            const SizedBox(width: 4),
                            TextButton(
                              onPressed: () {
                                onDismiss();
                                action.onPressed();
                              },
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 32),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: const StadiumBorder(),
                                textStyle: theme.textTheme.labelLarge?.copyWith(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0,
                                ),
                              ),
                              child: Text(action.label),
                            ),
                          ],
                        ],
                      ),
                    ),
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
