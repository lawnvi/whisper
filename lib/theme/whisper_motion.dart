import 'package:flutter/material.dart';

/// Keep spring movement small; opacity always follows a bounded curve.
abstract final class WhisperMotion {
  static const pageEnter = Duration(milliseconds: 360);
  static const pageExit = Duration(milliseconds: 240);
  static const dialogEnter = Duration(milliseconds: 300);
  static const dialogExit = Duration(milliseconds: 200);
  static const spring = Curves.easeOutBack;
}

/// Desktop pages arrive above a stationary workspace, without mobile parallax.
class WhisperDesktopPageTransitionsBuilder extends PageTransitionsBuilder {
  const WhisperDesktopPageTransitionsBuilder();

  @override
  Duration get transitionDuration => WhisperMotion.pageEnter;

  @override
  Duration get reverseTransitionDuration => WhisperMotion.pageExit;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return _DesktopPageTransition(animation: animation, child: child);
  }
}

class _DesktopPageTransition extends StatefulWidget {
  const _DesktopPageTransition({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<_DesktopPageTransition> createState() => _DesktopPageTransitionState();
}

class _DesktopPageTransitionState extends State<_DesktopPageTransition> {
  late final CurvedAnimation _position = CurvedAnimation(
    parent: widget.animation,
    curve: WhisperMotion.spring,
    reverseCurve: Curves.easeInCubic,
  );
  late final CurvedAnimation _opacity = CurvedAnimation(
    parent: widget.animation,
    curve: const Interval(0, 0.72, curve: Curves.easeOutCubic),
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void dispose() {
    _position.dispose();
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: AnimatedBuilder(
      animation: _position,
      child: RepaintBoundary(child: widget.child),
      builder: (context, child) => Transform.translate(
        offset: Offset(0, 18 * (1 - _position.value)),
        child: Transform.scale(
          scale: .985 + .015 * _position.value,
          child: child,
        ),
      ),
    ),
  );
}
