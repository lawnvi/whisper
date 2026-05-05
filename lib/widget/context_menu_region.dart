import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class ContextMenuActionItem {
  const ContextMenuActionItem({
    required this.label,
    required this.onSelected,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onSelected;
  final bool enabled;
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

    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }

    final enabledItems = <int, ContextMenuActionItem>{};
    final entries = <PopupMenuEntry<int>>[];

    for (var i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      if (!item.enabled) {
        continue;
      }
      enabledItems[i] = item;
      entries.add(PopupMenuItem<int>(
        value: i,
        child: Text(item.label),
      ));
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
    );

    if (selected != null) {
      enabledItems[selected]?.onSelected();
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
