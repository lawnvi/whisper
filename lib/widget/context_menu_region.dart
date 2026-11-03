import 'package:whisper/page/remote_files/files_menu.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:whisper/widget/glass_bottom_sheet.dart';

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

/// Shows [items] as a desktop menu at [anchor], given in global
/// coordinates. The menu opens from the anchor's top-left corner, or with
/// [above] sits over the anchor and ends at its right edge, the way a menu
/// opens from a button at the bottom of the window.
Future<void> showWhisperActionMenu(
  BuildContext context, {
  required Rect anchor,
  required List<ContextMenuActionItem> items,
  bool above = false,
}) async {
  final shown = [
    for (final item in items)
      if (item.enabled) item,
  ];
  if (shown.isEmpty) return;
  // Above the anchor when that is where there is room, as the composer's is.
  final height = shown.length * 30.0 + 12;
  await showFilesMenu(
    context,
    position: above
        ? Offset(anchor.right, anchor.top - height - 6)
        : anchor.bottomLeft + const Offset(0, 4),
    alignRight: above,
    items: [
      for (final (i, item) in shown.indexed) ...[
        if (i > 0 && item.destructive != shown[i - 1].destructive)
          const FilesMenuItem.separator(),
        FilesMenuItem(
          label: item.label,
          destructive: item.destructive,
          onSelected: item.onSelected,
        ),
      ],
    ],
  );
  return;
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

    await showWhisperActionMenu(
      context,
      anchor: globalPosition & Size.zero,
      items: widget.items,
    );
  }

  Future<void> _showMobileMenu(BuildContext context) async {
    final items = widget.items.where((item) => item.enabled).toList();
    if (items.isEmpty) {
      return;
    }
    final selected = await showWhisperGlassBottomSheet<int>(
      context,
      builder: (sheetContext) => WhisperGlassActionSheet(
        actions: [
          for (var i = 0; i < items.length; i++)
            WhisperGlassActionSheetAction(
              label: items[i].label,
              icon: items[i].icon,
              destructive: items[i].destructive,
              onPressed: () => Navigator.of(sheetContext).pop(i),
            ),
        ],
        cancelButton: WhisperGlassActionSheetAction(
          label: MaterialLocalizations.of(sheetContext).cancelButtonLabel,
          defaultAction: true,
          onPressed: () => Navigator.of(sheetContext).pop(),
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
