import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';

class ContextMenuActionItem {
  const ContextMenuActionItem({
    required this.label,
    required this.onSelected,
    required this.icon,
    this.enabled = true,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onSelected;
  final IconData icon;
  final bool enabled;
  final bool destructive;
}

class ContextMenuRegion extends StatefulWidget {
  const ContextMenuRegion({
    super.key,
    required this.child,
    required this.items,
  });

  final Widget child;
  final List<ContextMenuActionItem> items;

  @override
  State<ContextMenuRegion> createState() => _ContextMenuRegionState();
}

class _ContextMenuRegionState extends State<ContextMenuRegion> {
  Timer? _longPressTimer;
  Offset? _longPressOrigin;

  @override
  void dispose() {
    _cancelLongPressTimer();
    super.dispose();
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressOrigin = null;
  }

  Future<void> _showMenu(BuildContext context, Offset globalPosition) async {
    if (widget.items.isEmpty) {
      return;
    }

    final platform = Theme.of(context).platform;
    final isDesktop =
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
    if (!isDesktop) {
      await _showMobileMenu(context);
      return;
    }

    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }

    final enabledItems = <int, ContextMenuActionItem>{};
    final entries = <PopupMenuEntry<int>>[];
    final palette = context.whisperPalette;
    final colorScheme = Theme.of(context).colorScheme;

    for (var i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      if (!item.enabled) {
        continue;
      }
      enabledItems[i] = item;
      entries.add(
        PopupMenuItem<int>(
          value: i,
          height: 44,
          child: Row(
            children: [
              Icon(
                item.icon,
                size: 20,
                color: item.destructive
                    ? palette.danger
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.label,
                  style: TextStyle(
                    color: item.destructive
                        ? palette.danger
                        : colorScheme.onSurface,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (entries.isEmpty) {
      return;
    }

    final selected = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: entries,
      color: palette.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      constraints: const BoxConstraints(minWidth: 208, maxWidth: 288),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: palette.borderSubtle),
      ),
    );

    if (selected != null) {
      enabledItems[selected]?.onSelected();
    }
  }

  Future<void> _showMobileMenu(BuildContext context) async {
    final items = widget.items.where((item) => item.enabled).toList();
    if (items.isEmpty) {
      return;
    }
    final palette = context.whisperPalette;
    final colorScheme = Theme.of(context).colorScheme;
    final selected = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: palette.surfaceElevated,
      constraints: const BoxConstraints(maxWidth: 560),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < items.length; i++)
              ListTile(
                minTileHeight: 48,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                leading: Icon(
                  items[i].icon,
                  size: 22,
                  color: items[i].destructive
                      ? palette.danger
                      : colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  items[i].label,
                  style: TextStyle(
                    color: items[i].destructive
                        ? palette.danger
                        : colorScheme.onSurface,
                    fontSize: 15,
                  ),
                ),
                onTap: () => Navigator.of(context).pop(i),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      items[selected].onSelected();
    }
  }

  void _startLongPressTimer(PointerDownEvent event) {
    if (kIsWeb) {
      return;
    }
    if (event.buttons != kPrimaryButton) {
      return;
    }

    _cancelLongPressTimer();
    final globalPosition = event.position;
    _longPressOrigin = globalPosition;
    _longPressTimer = Timer(kLongPressTimeout, () {
      _longPressTimer = null;
      _longPressOrigin = null;
      if (!mounted) {
        return;
      }
      _showMenu(context, globalPosition);
    });
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final origin = _longPressOrigin;
    if (origin == null) {
      return;
    }
    if ((event.position - origin).distance > kTouchSlop) {
      _cancelLongPressTimer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _startLongPressTimer,
      onPointerMove: _handlePointerMove,
      onPointerUp: (_) => _cancelLongPressTimer(),
      onPointerCancel: (_) => _cancelLongPressTimer(),
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onSecondaryTapDown: (details) {
          _showMenu(context, details.globalPosition);
        },
        child: widget.child,
      ),
    );
  }
}
