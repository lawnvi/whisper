import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../window_stream/remote/remote_peer_source.dart';
import '../flow_space_theme.dart';

/// One button of the viewer's floating capsule.
class ViewerChromeButton extends StatelessWidget {
  const ViewerChromeButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          minimumSize: const Size(44, 44),
          pressedOpacity: 0.5,
          onPressed: () {
            HapticFeedback.selectionClick();
            onPressed();
          },
          child: AnimatedSwitcher(
            duration: flowReduceMotion(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: Icon(
              icon,
              key: ValueKey(icon),
              size: 20,
              color: active ? FlowSpaceTokens.live : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// The viewer's floating material: a dark frosted capsule with a fine
/// light edge, so it reads over the black around the picture as well as
/// over the picture itself, whatever the app's theme.
class ViewerGlass extends StatelessWidget {
  const ViewerGlass({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  static const Color tint = Color(0xC72C2C2E);
  static const Color edge = Color(0x24FFFFFF);

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: const ShapeBorderClipper(shape: StadiumBorder()),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: const ShapeDecoration(
            shape: StadiumBorder(side: BorderSide(color: edge, width: 0.5)),
            color: tint,
          ),
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      ),
    );
  }
}

/// The capsule itself: frosted, dark, centred.
class ViewerChromeCapsule extends StatelessWidget {
  const ViewerChromeCapsule({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ViewerGlass(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// While the controls are hidden, a small handle shows where they are; a
/// tap or a swipe up brings them back.
class ViewerGrabber extends StatelessWidget {
  const ViewerGrabber({super.key, required this.visible, required this.onShow});

  final bool visible;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: FlowSpaceTokens.quickDuration,
      opacity: visible ? 1 : 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onShow,
          onVerticalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0) < -100) {
              onShow();
            }
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(44, 14, 44, 10),
            child: Container(
              width: 44,
              height: 5,
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the input method is still composing (pinyin, a word being
/// predicted), underlined like marked text on a Mac, until it commits and
/// goes to the other device.
class ViewerComposingChip extends StatelessWidget {
  const ViewerComposingChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = flowReduceMotion(context);
    return AnimatedSwitcher(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 160),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: reduceMotion
            ? child
            : ScaleTransition(
                scale: Tween(begin: 0.94, end: 1.0).animate(animation),
                child: child,
              ),
      ),
      child: text.isEmpty
          ? const SizedBox.shrink(key: ValueKey('none'))
          : DecoratedBox(
              key: const ValueKey('composing'),
              decoration: const ShapeDecoration(
                shape: StadiumBorder(),
                color: Color(0xE01C1C1E),
                shadows: [
                  BoxShadow(
                    color: Color(0x55000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    decoration: TextDecoration.underline,
                    decorationColor: Color(0xB3FFFFFF),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Aa: how big a Mac window's content looks here. Five detents like a
/// ruler; dragging clicks through them, the choice applies on release.
class ViewerTextScaleRuler extends StatefulWidget {
  const ViewerTextScaleRuler({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<ViewerTextScaleRuler> createState() => _ViewerTextScaleRulerState();
}

class _ViewerTextScaleRulerState extends State<ViewerTextScaleRuler> {
  late int _index = _indexOf(widget.value);

  static int _indexOf(double value) {
    const steps = RemoteViewport.steps;
    var best = 0;
    for (var i = 1; i < steps.length; i++) {
      if ((steps[i] - value).abs() < (steps[best] - value).abs()) {
        best = i;
      }
    }
    return best;
  }

  void _pick(double dx, double width) {
    const steps = RemoteViewport.steps;
    final index = ((dx / width) * (steps.length - 1)).round().clamp(
      0,
      steps.length - 1,
    );
    if (index != _index) {
      HapticFeedback.selectionClick();
      setState(() => _index = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    const steps = RemoteViewport.steps;
    return ViewerGlass(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('A', style: TextStyle(color: Colors.white, fontSize: 13)),
          const SizedBox(width: 12),
          SizedBox(
            width: 180,
            height: 32,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    _pick(details.localPosition.dx, width);
                    widget.onChanged(steps[_index]);
                  },
                  onHorizontalDragUpdate: (details) =>
                      _pick(details.localPosition.dx, width),
                  onHorizontalDragEnd: (_) => widget.onChanged(steps[_index]),
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Container(
                        height: 2,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                      for (var i = 0; i < steps.length; i++)
                        Positioned(
                          left: i / (steps.length - 1) * (width - 6),
                          child: Container(
                            width: 6,
                            height: 12,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      AnimatedPositioned(
                        duration: flowReduceMotion(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        left: _index / (steps.length - 1) * (width - 26),
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x55000000),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'A',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
