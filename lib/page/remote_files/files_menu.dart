import 'dart:math' as math;

import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const double _menuMinWidth = 190;
const double _menuMaxWidth = 320;
const double _menuEdge = 8;

/// One row of a [showFilesMenu] menu, a separator, or a submenu.
class FilesMenuItem {
  const FilesMenuItem({
    required this.label,
    this.icon,
    this.leading,
    this.shortcut,
    this.onSelected,
    this.enabled = true,
    this.destructive = false,
    this.checked = false,
    this.children,
  }) : separator = false;

  const FilesMenuItem.separator()
    : label = '',
      icon = null,
      leading = null,
      shortcut = null,
      onSelected = null,
      enabled = false,
      destructive = false,
      checked = false,
      children = null,
      separator = true;

  final String label;
  final IconData? icon;

  /// Instead of [icon]: tinted by the icon theme, accent until highlighted.
  final Widget? leading;

  /// Shown on the right on desktops, e.g. "⌘C".
  final String? shortcut;
  final VoidCallback? onSelected;
  final bool enabled;
  final bool destructive;
  final bool checked;
  final List<FilesMenuItem>? children;
  final bool separator;

  bool get selectable =>
      !separator && enabled && (onSelected != null || children != null);
}

/// "⌘C" on a Mac, "Ctrl+C" elsewhere.
String filesShortcut(String key, {bool shift = false}) {
  final mac = defaultTargetPlatform == TargetPlatform.macOS;
  if (mac) {
    return '${shift ? '⇧' : ''}⌘$key';
  }
  return 'Ctrl+${shift ? 'Shift+' : ''}$key';
}

/// Shows a menu at [position] (global): a compact macOS-style menu with
/// shortcuts and submenus on desktops, an iOS pull-down menu on touch
/// screens. Up/Down/Enter/Esc work while it is open.
Future<void> showFilesMenu(
  BuildContext context, {
  required Offset position,
  required List<FilesMenuItem> items,
  bool touch = false,
  bool alignRight = false,
}) async {
  if (!items.any((item) => item.selectable)) {
    return;
  }
  final selected = await Navigator.of(context).push<FilesMenuItem>(
    _FilesMenuRoute(
      position: position,
      items: items,
      touch: touch,
      alignRight: alignRight,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
  selected?.onSelected?.call();
}

class _FilesMenuRoute extends PopupRoute<FilesMenuItem> {
  _FilesMenuRoute({
    required this.position,
    required this.items,
    required this.touch,
    required this.alignRight,
    required this.barrierLabel,
  });

  final Offset position;
  final List<FilesMenuItem> items;
  final bool touch;
  final bool alignRight;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => touch ? Radix.blackA2 : null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => Duration(milliseconds: touch ? 260 : 120);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 100);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _MenuLayer(
      position: position,
      items: items,
      touch: touch,
      alignRight: alignRight,
      animation: animation,
      onSelected: (item) => Navigator.of(context).pop(item),
    );
  }
}

class _MenuLayer extends StatefulWidget {
  const _MenuLayer({
    required this.position,
    required this.items,
    required this.touch,
    required this.alignRight,
    required this.animation,
    required this.onSelected,
  });

  final Offset position;
  final List<FilesMenuItem> items;
  final bool touch;
  final bool alignRight;
  final Animation<double> animation;
  final ValueChanged<FilesMenuItem> onSelected;

  @override
  State<_MenuLayer> createState() => _MenuLayerState();
}

class _MenuLayerState extends State<_MenuLayer> {
  /// The open submenu: the parent row's rect and its items.
  (Rect, List<FilesMenuItem>)? _submenu;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    // On a desktop a menu is as wide as its longest row; a touch menu is one size.
    final width = widget.touch ? 250.0 : null;
    final submenu = _submenu;
    final safeTop = padding.top + 8;
    final safeBottom = size.height - padding.bottom - 8;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _MenuPlacement(
              pointer: widget.position,
              alignRight: widget.alignRight,
              width: width,
              safeTop: safeTop,
              safeBottom: safeBottom,
            ),
            child: IntrinsicWidth(
              child: _AnimatedMenu(
                animation: widget.animation,
                touch: widget.touch,
                alignRight: widget.alignRight,
                child: _MenuPanel(
                  items: widget.items,
                  touch: widget.touch,
                  autofocus: true,
                  onSelected: widget.onSelected,
                  onSubmenu: (rect, children) =>
                      setState(() => _submenu = (rect, children)),
                ),
              ),
            ),
          ),
        ),
        if (submenu != null)
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _SubmenuPlacement(
                row: submenu.$1,
                width: width,
                safeTop: safeTop,
                safeBottom: safeBottom,
              ),
              child: IntrinsicWidth(
                child: _MenuPanel(
                  key: ValueKey(submenu.$2),
                  items: submenu.$2,
                  touch: widget.touch,
                  autofocus: false,
                  onSelected: widget.onSelected,
                  onSubmenu: (_, _) {},
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// [width] when it is one size, otherwise the range the longest row moves in.
BoxConstraints _menuWidth(BoxConstraints window, double? width) {
  final most = math.max(0.0, window.maxWidth - 2 * _menuEdge);
  return width != null
      ? BoxConstraints.tightFor(width: math.min(width, most))
      : BoxConstraints(
          minWidth: math.min(_menuMinWidth, most),
          maxWidth: math.min(_menuMaxWidth, most),
        );
}

/// Grows from the pointer like a native menu, and keeps the panel on
/// screen when it would run off the bottom.
/// Under the pointer when it fits, over it when it does not, and when it fits in
/// neither, as much of it as the window holds, on the side with more room, and it
/// scrolls. A menu that runs off the window is a menu you cannot read.
class _MenuPlacement extends SingleChildLayoutDelegate {
  const _MenuPlacement({
    required this.pointer,
    required this.alignRight,
    required this.width,
    required this.safeTop,
    required this.safeBottom,
  });

  final Offset pointer;
  final bool alignRight;
  final double? width;
  final double safeTop, safeBottom;

  double get _below => safeBottom - pointer.dy;
  double get _above => pointer.dy - safeTop;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      _menuWidth(
        constraints,
        width,
      ).copyWith(maxHeight: math.max(0, math.max(_below, _above)));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final left = alignRight ? pointer.dx - child.width : pointer.dx;
    final under = child.height <= _below || _below >= _above;
    return Offset(
      left.clamp(
        _menuEdge,
        math.max(_menuEdge, size.width - child.width - _menuEdge),
      ),
      under ? pointer.dy : pointer.dy - child.height,
    );
  }

  @override
  bool shouldRelayout(_MenuPlacement old) =>
      old.pointer != pointer ||
      old.alignRight != alignRight ||
      old.width != width ||
      old.safeTop != safeTop ||
      old.safeBottom != safeBottom;
}

/// Beside its row, on the side it fits, and up as far as it takes for its last
/// row to be in the window.
class _SubmenuPlacement extends SingleChildLayoutDelegate {
  const _SubmenuPlacement({
    required this.row,
    required this.width,
    required this.safeTop,
    required this.safeBottom,
  });

  final Rect row;
  final double? width;
  final double safeTop, safeBottom;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      _menuWidth(
        constraints,
        width,
      ).copyWith(maxHeight: math.max(0, safeBottom - safeTop));

  @override
  Offset getPositionForChild(Size size, Size child) => Offset(
    row.right + child.width + 4 < size.width
        ? row.right + 2
        : row.left - child.width - 2,
    math.max(safeTop, math.min(row.top - 5, safeBottom - child.height)),
  );

  @override
  bool shouldRelayout(_SubmenuPlacement old) =>
      old.row != row ||
      old.width != width ||
      old.safeTop != safeTop ||
      old.safeBottom != safeBottom;
}

class _AnimatedMenu extends StatelessWidget {
  const _AnimatedMenu({
    required this.animation,
    required this.touch,
    required this.alignRight,
    required this.child,
  });

  final Animation<double> animation;
  final bool touch;
  final bool alignRight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: touch ? Curves.easeOutBack : Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween(begin: touch ? 0.6 : 0.96, end: 1.0).animate(curved),
        alignment: alignRight ? Alignment.topRight : Alignment.topLeft,
        child: child,
      ),
    );
  }
}

class _MenuPanel extends StatefulWidget {
  const _MenuPanel({
    super.key,
    required this.items,
    required this.touch,
    required this.autofocus,
    required this.onSelected,
    required this.onSubmenu,
  });

  final List<FilesMenuItem> items;
  final bool touch;
  final bool autofocus;
  final ValueChanged<FilesMenuItem> onSelected;
  final void Function(Rect rect, List<FilesMenuItem> children) onSubmenu;

  @override
  State<_MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<_MenuPanel> {
  int? _active;
  final _keys = <int, GlobalKey>{};
  Timer? _submenuTimer;

  @override
  void dispose() {
    _submenuTimer?.cancel();
    super.dispose();
  }

  void _activate(int? index, {bool openSubmenu = true}) {
    setState(() => _active = index);
    _submenuTimer?.cancel();
    if (index == null || !openSubmenu) {
      return;
    }
    final children = widget.items[index].children;
    if (children != null) {
      _submenuTimer = Timer(const Duration(milliseconds: 120), () {
        final box =
            _keys[index]?.currentContext?.findRenderObject() as RenderBox?;
        if (box != null && mounted) {
          widget.onSubmenu(box.localToGlobal(Offset.zero) & box.size, children);
        }
      });
    }
  }

  void _choose(int index) {
    final item = widget.items[index];
    if (!item.selectable) {
      return;
    }
    if (item.children != null) {
      _activate(index);
      return;
    }
    HapticFeedback.selectionClick();
    widget.onSelected(item);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final selectable = [
      for (var i = 0; i < widget.items.length; i++)
        if (widget.items[i].selectable) i,
    ];
    if (selectable.isEmpty) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final at = _active == null ? -1 : selectable.indexOf(_active!);
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final next = at < 0
          ? (step > 0 ? 0 : selectable.length - 1)
          : (at + step) % selectable.length;
      _activate(selectable[next], openSubmenu: false);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.arrowRight) &&
        _active != null) {
      _choose(_active!);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(WhisperRadius.m),
      side: BorderSide(color: dark ? Radix.whiteA2 : Radix.blackA2, width: 0.5),
    );
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          shadows: WhisperShadow.e2(Theme.of(context).brightness),
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: shape,
                color: context.wc.panelTint,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(widget.touch ? 0 : 5),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < widget.items.length; i++)
                        widget.items[i].separator
                            ? _Separator(touch: widget.touch, dark: dark)
                            : _Row(
                                key: _keys.putIfAbsent(i, GlobalKey.new),
                                item: widget.items[i],
                                touch: widget.touch,
                                active: _active == i,
                                onHover: (inside) {
                                  if (inside) {
                                    _activate(i);
                                  } else if (_active == i &&
                                      widget.items[i].children == null) {
                                    _activate(null);
                                  }
                                },
                                onTap: () => _choose(i),
                              ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator({required this.touch, required this.dark});

  final bool touch;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    if (touch) {
      return Container(height: 8, color: dark ? Radix.blackA4 : Radix.blackA1);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
      child: Container(
        height: 0.5,
        color: dark ? Radix.whiteA3 : Radix.blackA2,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.item,
    required this.touch,
    required this.active,
    required this.onHover,
    required this.onTap,
  });

  final FilesMenuItem item;
  final bool touch;
  final bool active;
  final ValueChanged<bool> onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = context.wc;
    final accent = c.accent;
    final red = c.bad;
    final label = c.ink;
    final secondary = dark ? Radix.whiteA7 : Radix.blackA6;
    final enabled = item.selectable;
    final highlighted = active && enabled && !touch;
    final Color fg;
    if (!enabled) {
      fg = secondary.withValues(alpha: 0.6);
    } else if (highlighted) {
      fg = Colors.white;
    } else if (item.destructive) {
      fg = red;
    } else {
      fg = label;
    }
    if (touch) {
      return _TouchRow(
        item: item,
        fg: fg,
        dark: dark,
        onTap: enabled ? onTap : null,
      );
    }
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          constraints: BoxConstraints(minHeight: 30),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: highlighted ? accent : Colors.transparent,
            borderRadius: BorderRadius.circular(WhisperRadius.menuRow),
          ),
          child: Row(
            children: [
              if (item.leading != null) ...[
                IconTheme(
                  data: IconThemeData(
                    color: highlighted ? Colors.white : accent,
                  ),
                  child: item.leading!,
                ),
                const SizedBox(width: 9),
              ] else if (item.icon != null) ...[
                Icon(
                  item.icon,
                  size: 14,
                  color: highlighted
                      ? Colors.white
                      : item.destructive && enabled
                      ? red
                      : enabled
                      ? secondary
                      : fg,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: const WhisperType(touch: false).body,
                    height: 1.2,
                  ),
                ),
              ),
              if (item.checked) ...[
                const SizedBox(width: 9),
                WhisperIcon(WhisperGlyph.check, size: 14, weight: 2, color: fg),
              ],
              if (item.shortcut != null)
                Text(
                  item.shortcut!,
                  style: TextStyle(
                    color: highlighted ? Radix.whiteA10 : secondary,
                    fontSize: 12.5,
                  ),
                ),
              if (item.children != null)
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 11,
                  color: highlighted ? Colors.white : secondary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// iOS pull-down row: label on the left, symbol on the right, pressed
/// state, and a check for the chosen option.
class _TouchRow extends StatefulWidget {
  const _TouchRow({
    required this.item,
    required this.fg,
    required this.dark,
    required this.onTap,
  });

  final FilesMenuItem item;
  final Color fg;
  final bool dark;
  final VoidCallback? onTap;

  @override
  State<_TouchRow> createState() => _TouchRowState();
}

class _TouchRowState extends State<_TouchRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: _pressed
              ? (widget.dark ? Radix.whiteA2 : Radix.blackA1)
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: widget.dark ? Radix.whiteA2 : Radix.blackA2,
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: item.checked
                  ? Icon(
                      CupertinoIcons.checkmark_alt,
                      size: 17,
                      color: widget.fg,
                    )
                  : null,
            ),
            Expanded(
              child: Text(
                item.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: widget.fg, fontSize: 16.5),
              ),
            ),
            if (item.icon != null)
              Icon(item.icon, size: 19, color: widget.fg)
            else if (item.children != null)
              Icon(CupertinoIcons.chevron_right, size: 15, color: widget.fg),
          ],
        ),
      ),
    );
  }
}
