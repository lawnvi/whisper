import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/device_connection_widgets.dart';

/// Search takes the space left by the visible buttons, including mid-animation.
class DeviceSidebarToolbar extends StatelessWidget {
  const DeviceSidebarToolbar({
    super.key,
    required this.search,
    required this.tools,
    required this.searchExpanded,
  });

  final Widget search;
  final List<Widget> tools;
  final bool searchExpanded;

  static const _duration = Duration(milliseconds: 340);

  @override
  Widget build(BuildContext context) {
    final toolsWidth = tools.isEmpty
        ? 0.0
        : 6 + tools.length * DeviceToolbarButton.width + (tools.length - 1) * 2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(key: const ValueKey('sidebar-search'), child: search),
            AnimatedContainer(
              duration: _duration,
              curve: Curves.easeOutCubic,
              width: searchExpanded || tools.isEmpty ? 0 : 10,
            ),
            ClipRect(
              child: AnimatedContainer(
                duration: _duration,
                curve: Curves.easeOutCubic,
                width: searchExpanded ? 0 : toolsWidth,
                child: OverflowBox(
                  alignment: Alignment.centerRight,
                  minWidth: toolsWidth,
                  maxWidth: toolsWidth,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 140),
                    opacity: searchExpanded ? 0 : 1,
                    child: IgnorePointer(
                      ignoring: searchExpanded,
                      child: Container(
                        key: const ValueKey('sidebar-tools'),
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: context.whisperPalette.surfaceMuted,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            for (
                              var index = 0;
                              index < tools.length;
                              index++
                            ) ...[
                              if (index > 0) const SizedBox(width: 2),
                              ToolEntrance(
                                key: tools[index].key == null
                                    ? null
                                    : ValueKey(('entrance', tools[index].key)),
                                // Tools coming in arrive one after another,
                                // from the toggle outwards.
                                delay: Duration(milliseconds: 35 * index),
                                child: tools[index],
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
          ],
        ),
      ),
    );
  }
}

/// A tool that just appeared fades and scales in after [delay]; tools that
/// were already there stay as they are.
class ToolEntrance extends StatefulWidget {
  const ToolEntrance({super.key, required this.delay, required this.child});

  final Duration delay;
  final Widget child;

  @override
  State<ToolEntrance> createState() => ToolEntranceState();
}

class ToolEntranceState extends State<ToolEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  Timer? _start;

  @override
  void initState() {
    super.initState();
    _start = Timer(widget.delay, () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _start?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
    );
    return FadeTransition(
      opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween(begin: 0.6, end: 1.0).animate(curve),
        child: widget.child,
      ),
    );
  }
}
