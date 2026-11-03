import 'dart:math' as math;

import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  Color? get barrierColor =>
      touch ? Colors.black.withValues(alpha: 0.08) : null;

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
    final width = widget.touch ? 250.0 : 236.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final left = widget.alignRight
            ? widget.position.dx - width
            : widget.position.dx;
        final x = left.clamp(8.0, size.width - width - 8);
        final submenu = _submenu;
        final safeTop = padding.top + 8;
        final safeBottom = size.height - padding.bottom - 8;
        return Stack(
          children: [
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: _MenuPlacement(
                  anchor: Offset(x, widget.position.dy),
                  width: width,
                  safeTop: safeTop,
                  safeBottom: safeBottom,
                ),
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
            if (submenu != null)
              Positioned(
                left: (submenu.$1.right + width + 4 < size.width)
                    ? submenu.$1.right + 2
                    : submenu.$1.left - width - 2,
                // Up as far as it takes for its last row to be in the window.
                top: math.max(
                  safeTop,
                  math.min(
                    submenu.$1.top - 5,
                    safeBottom -
                        submenu.$2.length * (widget.touch ? 48.0 : 30.0) -
                        12,
                  ),
                ),
                width: width,
                child: _MenuPanel(
                  key: ValueKey(submenu.$2),
                  items: submenu.$2,
                  touch: widget.touch,
                  autofocus: false,
                  onSelected: widget.onSelected,
                  onSubmenu: (_, _) {},
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Grows from the pointer like a native menu, and keeps the panel on
/// screen when it would run off the bottom.
/// Under the pointer when it fits, over it when it does not, and when it fits in
/// neither, as much of it as the window holds, on the side with more room, and it
/// scrolls. A menu that runs off the window is a menu you cannot read.
class _MenuPlacement extends SingleChildLayoutDelegate {
  const _MenuPlacement({
    required this.anchor,
    required this.width,
    required this.safeTop,
    required this.safeBottom,
  });

  final Offset anchor;
  final double width, safeTop, safeBottom;

  double get _below => safeBottom - anchor.dy;
  double get _above => anchor.dy - safeTop;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: math.max(0, math.max(_below, _above)),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    final under = child.height <= _below || _below >= _above;
    return Offset(anchor.dx, under ? anchor.dy : anchor.dy - child.height);
  }

  @override
  bool shouldRelayout(_MenuPlacement old) =>
      old.anchor != anchor ||
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
    final radius = whisperNewUi
        ? WhisperRadius.m
        : widget.touch
        ? 16.0
        : 11.0;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(
        color: dark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.1),
        width: 0.5,
      ),
    );
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          shadows: whisperNewUi
              ? WhisperShadow.e2(Theme.of(context).brightness)
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.5 : 0.18),
                    blurRadius: widget.touch ? 40 : 24,
                    offset: const Offset(0, 10),
                  ),
                ],
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: shape,
                color: whisperNewUi
                    ? context.wc.panelTint
                    : dark
                    ? const Color(0xFF2A2A2D).withValues(alpha: 0.86)
                    : const Color(0xFFF7F7F9).withValues(alpha: 0.86),
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
      return Container(
        height: 8,
        color: dark
            ? Colors.black.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.06),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
      child: Container(
        height: 0.5,
        color: dark
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.black.withValues(alpha: 0.12),
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
    final accent = dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
    final red = dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);
    final label = dark ? Colors.white : const Color(0xFF1C1C1E);
    final secondary = dark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.45);
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
    final check = SizedBox(
      width: touch ? 0 : 16,
      child: item.checked && !touch
          ? Icon(CupertinoIcons.checkmark_alt, size: 13, color: fg)
          : null,
    );
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
          constraints: BoxConstraints(minHeight: whisperNewUi ? 30 : 24),
          padding: whisperNewUi
              ? const EdgeInsets.symmetric(horizontal: 9, vertical: 4)
              : const EdgeInsets.only(left: 4, right: 9),
          decoration: BoxDecoration(
            color: highlighted ? accent : Colors.transparent,
            borderRadius: BorderRadius.circular(
              whisperNewUi ? WhisperRadius.xs : 6,
            ),
          ),
          child: Row(
            children: [
              if (!whisperNewUi) check,
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
                    fontSize: whisperNewUi ? 14 : 13,
                    height: 1.2,
                  ),
                ),
              ),
              if (whisperNewUi && item.checked) ...[
                const SizedBox(width: 9),
                WhisperIcon(WhisperGlyph.check, size: 14, weight: 2, color: fg),
              ],
              if (item.shortcut != null)
                Text(
                  item.shortcut!,
                  style: TextStyle(
                    color: highlighted
                        ? Colors.white.withValues(alpha: 0.85)
                        : secondary,
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
              ? (widget.dark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.07))
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: widget.dark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.08),
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
