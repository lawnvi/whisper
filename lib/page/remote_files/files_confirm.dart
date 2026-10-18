import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../window_stream/flow_space_theme.dart';

/// Asks before something that cannot be undone (deleting for good). On a
/// wide window a card springs up in the middle; on a phone a sheet rises
/// from the bottom with the buttons in reach of the thumb. It names what
/// is affected; the destructive button is red. True when confirmed.
Future<bool> showFilesConfirm(
  BuildContext context, {
  required String title,
  required String detail,
  required String confirmLabel,
  List<String> names = const [],
  IconData icon = CupertinoIcons.trash,
}) async {
  HapticFeedback.mediumImpact();
  final wide = MediaQuery.sizeOf(context).width >= 700;
  final confirmed = await Navigator.of(context).push<bool>(
    _ConfirmRoute(
      wide: wide,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (context) => _ConfirmCard(
        wide: wide,
        title: title,
        detail: detail,
        confirmLabel: confirmLabel,
        names: names,
        icon: icon,
      ),
    ),
  );
  return confirmed ?? false;
}

class _ConfirmRoute extends PopupRoute<bool> {
  _ConfirmRoute({
    required this.wide,
    required this.builder,
    required this.barrierLabel,
  });

  final bool wide;
  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.32);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 460);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (flowReduceMotion(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    // In: a spring that overshoots a touch. Out: quick and plain.
    final motion = CurvedAnimation(
      parent: animation,
      curve: const SpringCurve(FlowSpaceTokens.snappySpring, 0.46),
      reverseCurve: Curves.easeInCubic,
    );
    final fade = CurvedAnimation(
      parent: animation,
      curve: const Interval(0, 0.4, curve: Curves.easeOut),
      reverseCurve: Curves.easeIn,
    );
    return AnimatedBuilder(
      animation: motion,
      child: child,
      builder: (context, child) {
        final t = motion.value;
        return FadeTransition(
          opacity: fade,
          child: wide
              ? Transform.scale(scale: 0.9 + 0.1 * t, child: child)
              : FractionalTranslation(
                  translation: Offset(0, (1 - t) * 0.6),
                  child: child,
                ),
        );
      },
    );
  }
}

class _ConfirmCard extends StatelessWidget {
  const _ConfirmCard({
    required this.wide,
    required this.title,
    required this.detail,
    required this.confirmLabel,
    required this.names,
    required this.icon,
  });

  final bool wide;
  final String title;
  final String detail;
  final String confirmLabel;
  final List<String> names;
  final IconData icon;

  static const _red = Color(0xFFFF3B30);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = FlowSpaceColors.of(context);
    final media = MediaQuery.of(context);
    final shown = names.take(3).toList();
    final more = names.length - shown.length;
    void answer(bool value) {
      HapticFeedback.selectionClick();
      Navigator.of(context).pop(value);
    }

    final cancel = _Button(
      label: l10n.cancel,
      color: colors.dark
          ? Colors.white.withValues(alpha: 0.1)
          : Colors.black.withValues(alpha: 0.06),
      textColor: colors.label,
      onPressed: () => answer(false),
    );
    final confirm = _Button(
      label: confirmLabel,
      color: _red,
      textColor: Colors.white,
      autofocus: true,
      onPressed: () => answer(true),
    );
    final card = Material(
      type: MaterialType.transparency,
      child: Container(
        width: wide ? 360 : double.infinity,
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
        decoration: ShapeDecoration(
          color: colors.raised,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(wide ? 24 : 30),
            side: BorderSide(color: colors.hairline, width: 0.5),
          ),
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: colors.dark ? 0.5 : 0.18),
              blurRadius: 40,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: _red.withValues(alpha: colors.dark ? 0.2 : 0.1),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 24, color: _red),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.label,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.secondaryLabel,
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
            if (shown.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: ShapeDecoration(
                  color: colors.dark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.035),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final name in shown)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.label, fontSize: 13),
                        ),
                      ),
                    if (more > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          l10n.remoteFilesAndMore(more),
                          style: TextStyle(
                            color: colors.tertiaryLabel,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            if (wide)
              Row(
                children: [
                  Expanded(child: cancel),
                  const SizedBox(width: 10),
                  Expanded(child: confirm),
                ],
              )
            else ...[
              confirm,
              const SizedBox(height: 8),
              cancel,
            ],
          ],
        ),
      ),
    );
    final shortcuts = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => answer(false),
      },
      child: card,
    );
    if (wide) {
      return Center(child: shortcuts);
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          10,
          0,
          10,
          math.max(10, media.padding.bottom + 4),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: shortcuts,
        ),
      ),
    );
  }
}

class _Button extends StatefulWidget {
  const _Button({
    required this.label,
    required this.color,
    required this.textColor,
    required this.onPressed,
    this.autofocus = false,
  });

  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  State<_Button> createState() => _ButtonState();
}

class _ButtonState extends State<_Button> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed();
            return null;
          },
        ),
      },
      mouseCursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 120),
          scale: _down ? 0.97 : 1,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: _down ? 0.8 : 1,
            child: Container(
              height: 46,
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: widget.color,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color: widget.textColor,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
