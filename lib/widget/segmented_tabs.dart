import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';

class WhisperTabBar extends StatelessWidget {
  const WhisperTabBar({
    super.key,
    required this.controller,
    required this.tabs,
    this.scrollable = false,
    this.onTap,
  });

  final TabController controller;
  final List<Widget> tabs;
  final bool scrollable;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.whisperPalette;
    final radius = BorderRadius.circular(999);
    return Material(
      color: palette.surfaceMuted,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          height: MediaQuery.textScalerOf(context).scale(16) + 32,
          child: TabBar(
            controller: controller,
            onTap: onTap,
            dividerColor: Colors.transparent,
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorAnimation: TabIndicatorAnimation.elastic,
            indicator: ShapeDecoration(
              color: palette.surfaceElevated,
              shape: const StadiumBorder(),
            ),
            splashBorderRadius: radius,
            splashFactory: NoSplash.splashFactory,
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return theme.colorScheme.primary.withValues(alpha: .10);
              }
              if (states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused)) {
                return theme.colorScheme.primary.withValues(alpha: .06);
              }
              return Colors.transparent;
            }),
            labelColor: theme.colorScheme.onSurface,
            unselectedLabelColor: palette.textMuted,
            labelStyle: theme.textTheme.labelLarge,
            labelPadding: EdgeInsets.symmetric(horizontal: scrollable ? 12 : 4),
            isScrollable: scrollable,
            tabAlignment: scrollable ? TabAlignment.start : TabAlignment.fill,
            tabs: tabs,
          ),
        ),
      ),
    );
  }
}

/// Retains page state while outgoing content loses input and focus immediately.
class WhisperTabPanels extends StatefulWidget {
  const WhisperTabPanels({
    super.key,
    required this.selected,
    required this.children,
    this.fit = StackFit.expand,
  });

  final int selected;
  final List<Widget> children;
  final StackFit fit;

  @override
  State<WhisperTabPanels> createState() => _WhisperTabPanelsState();
}

class _WhisperTabPanelsState extends State<WhisperTabPanels> {
  double _direction = 1;

  @override
  void didUpdateWidget(WhisperTabPanels oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected) {
      _direction = widget.selected > oldWidget.selected ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: widget.fit,
    alignment: Alignment.topCenter,
    clipBehavior: Clip.hardEdge,
    children: [
      for (var index = 0; index < widget.children.length; index++)
        TweenAnimationBuilder<double>(
          tween: Tween(
            begin: index == widget.selected ? 1 : 0,
            end: index == widget.selected ? 1 : 0,
          ),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 240),
          curve: Curves.easeInOutCubic,
          builder: (context, progress, child) {
            final active = index == widget.selected;
            // Fade through instead of mixing outgoing and incoming content.
            final opacity =
                ((progress - (active ? .35 : .65)) / (active ? .65 : .35))
                    .clamp(0.0, 1.0);
            return Offstage(
              offstage: opacity == 0,
              child: Opacity(
                opacity: Curves.easeOutCubic.transform(opacity),
                child: Transform.translate(
                  offset: Offset(
                    (1 - progress) * 12 * (active ? _direction : -_direction),
                    0,
                  ),
                  child: child,
                ),
              ),
            );
          },
          child: IgnorePointer(
            ignoring: index != widget.selected,
            child: ExcludeFocus(
              excluding: index != widget.selected,
              child: ExcludeSemantics(
                excluding: index != widget.selected,
                child: TickerMode(
                  enabled: index == widget.selected,
                  child: widget.children[index],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
