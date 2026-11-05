import 'dart:async';

import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/radix_colors.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/new_ui/shell/shell_island_sources.dart';
import 'package:flutter/material.dart';
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

/// The toast on screen: one at a time, a newer one replaces it.
_AppToast? _currentToast;

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
  // A desktop says it on the island. One with a button still needs a place to
  // keep the button until it is pressed, and with no island on screen (a small
  // window of its own) a toast is what is left.
  if (isDesktop() && action == null && NoteIslandSource.shared.watched) {
    NoteIslandSource.shared.note(
      message,
      problem: tone == AppToastTone.error || tone == AppToastTone.warning,
    );
    return;
  }
  final overlayState = appNavigatorKey.currentState?.overlay;
  if (overlayState == null) {
    privacyLog.event(PrivacyEvent.toastUnavailable, <PrivacyField, Object>{
      PrivacyField.reason: ToastUnavailableReason.noOverlay,
    });
    return;
  }

  try {
    _currentToast?.close();
    _currentToast = _AppToast(
      overlay: overlayState,
      duration:
          duration ?? appToastDurationFor(message, hasAction: action != null),
      builder: (close) => _AppToastView(
        message: message,
        tone: tone,
        action: action,
        onDismiss: close,
      ),
    );
  } catch (error) {
    privacyLog.event(PrivacyEvent.toastUnavailable, <PrivacyField, Object>{
      PrivacyField.reason: ToastUnavailableReason.renderFailure,
      PrivacyField.errorType: privacyLog.errorType(error),
    });
  }
}

/// One toast, in the app's overlay. Only the capsule takes touches, so what is
/// around it stays usable, the page's back button included.
class _AppToast {
  _AppToast({
    required OverlayState overlay,
    required Duration duration,
    required Widget Function(VoidCallback close) builder,
  }) : _animation = AnimationController(
         vsync: overlay,
         duration: const Duration(milliseconds: 240),
       ) {
    _entry = OverlayEntry(
      builder: (context) => Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: DefaultTextStyle(
              style: Theme.of(context).textTheme.bodyLarge!,
              child: _buildToastAnimation(context, _animation, builder(close)),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry);
    unawaited(_animation.forward());
    // Counted from the first frame. In the background there are none, and a
    // toast nobody has seen shouldn't be over when they come back.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!_closing) {
          _timer = Timer(duration, close);
        }
      })
      ..ensureVisualUpdate();
  }

  final AnimationController _animation;
  late final OverlayEntry _entry;
  Timer? _timer;
  bool _closing = false;

  void close() {
    if (_closing) {
      return;
    }
    _closing = true;
    _timer?.cancel();
    if (identical(_currentToast, this)) {
      _currentToast = null;
    }
    _animation.reverse().whenCompleteOrCancel(() {
      _entry.remove();
      _entry.dispose();
      _animation.dispose();
    });
  }
}

Widget _buildToastAnimation(
  BuildContext context,
  Animation<double> animation,
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
    final palette = context.wc;
    final (icon, iconColor) = switch (tone) {
      AppToastTone.info => (Icons.info_rounded, colorScheme.primary),
      AppToastTone.success => (Icons.check_circle_rounded, palette.ok),
      AppToastTone.warning => (Icons.warning_rounded, palette.warn),
      AppToastTone.error => (Icons.error_rounded, palette.bad),
    };
    final action = this.action;
    final isDark = theme.brightness == Brightness.dark;
    // A step lighter than the page in the dark theme, where the page itself
    // is black and a border alone would not lift the capsule off it.
    final surfaceColor = isDark
        ? Color.alphaBlend(Radix.whiteA2, palette.raised)
        : palette.raised;
    final borderColor = isDark ? Radix.whiteA3 : palette.sep;
    final shadowColor = isDark ? Colors.black : Radix.slate12;

    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        child: Center(
          heightFactor: 1,
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
