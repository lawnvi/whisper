import 'package:flutter/foundation.dart';
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

class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.child,
    required this.items,
  });

  final Widget child;
  final List<ContextMenuActionItem> items;

  Future<void> _showMenu(BuildContext context, Offset globalPosition) async {
    if (items.isEmpty) {
      return;
    }

    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }

    final enabledItems = <int, ContextMenuActionItem>{};
    final entries = <PopupMenuEntry<int>>[];

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onSecondaryTapDown: (details) {
        _showMenu(context, details.globalPosition);
      },
      onLongPressStart: (details) {
        if (!kIsWeb) {
          _showMenu(context, details.globalPosition);
        }
      },
      child: child,
    );
  }
}
