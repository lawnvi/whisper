import 'package:flutter/material.dart';

Duration whisperMotionDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 180);

// Keep the same wrapper when a child becomes outgoing, so focused controls are
// unfocused rather than reattached under a newly disabled focus ancestor.
Widget _motionChild(Widget child, {required bool active}) => IgnorePointer(
  key: child.key,
  ignoring: !active,
  child: ExcludeFocus(
    excluding: !active,
    child: ExcludeSemantics(excluding: !active, child: child),
  ),
);

Widget _motionLayout(
  Widget? current,
  List<Widget> previous,
  AlignmentGeometry alignment,
) => Stack(
  alignment: alignment,
  children: [
    for (final child in previous) _motionChild(child, active: false),
    if (current != null) _motionChild(current, active: true),
  ],
);

/// A small state change, with stable bounds supplied by the caller for icons.
class WhisperAnimatedSwitcher extends StatelessWidget {
  const WhisperAnimatedSwitcher({
    super.key,
    required this.value,
    required this.child,
    this.alignment = Alignment.center,
    this.scale = false,
  });

  final Object value;
  final Widget child;
  final AlignmentGeometry alignment;
  final bool scale;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return Align(
        alignment: alignment,
        widthFactor: 1,
        heightFactor: 1,
        child: child,
      );
    }
    return AnimatedSwitcher(
      duration: whisperMotionDuration(context),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) =>
          _motionLayout(current, previous, alignment),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: scale
            ? ScaleTransition(
                scale: Tween<double>(begin: .92, end: 1).animate(animation),
                child: child,
              )
            : child,
      ),
      child: KeyedSubtree(key: ValueKey(value), child: child),
    );
  }
}

/// Keeps disappearing content long enough to close, without keeping it active.
class WhisperAnimatedReveal extends StatefulWidget {
  const WhisperAnimatedReveal({
    super.key,
    required this.visible,
    required this.child,
    this.axis = Axis.vertical,
  }) : assert(!visible || child != null);

  final bool visible;
  final Widget? child;
  final Axis axis;

  @override
  State<WhisperAnimatedReveal> createState() => _WhisperAnimatedRevealState();
}

class _WhisperAnimatedRevealState extends State<WhisperAnimatedReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.visible ? 1 : 0,
  )..addStatusListener(_statusChanged);
  late final CurvedAnimation _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  Widget? _retainedChild;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _retainedChild = widget.visible ? widget.child : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _controller.value = widget.visible ? 1 : 0;
  }

  @override
  void didUpdateWidget(WhisperAnimatedReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) _retainedChild = widget.child;
    if (widget.visible == oldWidget.visible) return;
    if (_reduceMotion) {
      _controller.value = widget.visible ? 1 : 0;
      if (!widget.visible) _retainedChild = null;
    } else if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _statusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.visible) {
      setState(() => _retainedChild = null);
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    axis: widget.axis,
    axisAlignment: -1,
    sizeFactor: _animation,
    child: FadeTransition(
      opacity: _animation,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: ExcludeFocus(
          excluding: !widget.visible,
          child: ExcludeSemantics(
            excluding: !widget.visible,
            child: TickerMode(
              enabled: widget.visible,
              child: _retainedChild ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  );
}

class ConnectionStatusDot extends StatelessWidget {
  const ConnectionStatusDot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: whisperMotionDuration(context),
    curve: Curves.easeOutCubic,
    width: 8,
    height: 8,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}
