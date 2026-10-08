import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';
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
      if (enabledItems.isNotEmpty &&
          item.destructive != enabledItems.values.last.destructive) {
        entries.add(
          PopupMenuDivider(
            height: 9,
            thickness: 0.75,
            indent: 14,
            endIndent: 14,
            color: palette.borderSubtle,
          ),
        );
      }
      enabledItems[i] = item;
      entries.add(
        PopupMenuItem<int>(
          value: i,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  item.label,
                  style: TextStyle(
                    color: item.destructive
                        ? palette.danger
                        : colorScheme.onSurface,
                    fontSize: 15,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Icon(
                item.icon,
                size: 19,
                color: item.destructive
                    ? palette.danger
                    : colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      );
    }

    if (entries.isEmpty) {
      return;
    }

    final anchor = overlay.globalToLocal(globalPosition);
    final selected = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.dx, anchor.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: entries,
      color: palette.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      clipBehavior: Clip.antiAlias,
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: Duration(milliseconds: 180),
              reverseDuration: Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
            ),
      constraints: const BoxConstraints(minWidth: 224, maxWidth: 304),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
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
