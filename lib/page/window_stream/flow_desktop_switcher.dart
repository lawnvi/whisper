import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'flow_app_icon.dart';
import 'flow_recents_deck.dart';
import 'flow_space_theme.dart';

/// Every recent window at once over the page, the way a desktop shows its
/// windows (Mission Control, Task View): laid out in a grid that fits the
/// window, so a mouse reaches each one with a click and a long list
/// scrolls with the wheel. The cards lift out of the stack the user
/// clicked ([origins]: each card's rect there) and go back into it on the
/// way out; completes once they are there, for the stack to show again.
///
/// Only the cards move, each on its own layer, over a plain dim: nothing
/// behind is blurred, so it keeps its frame rate on any GPU.
Future<void> showFlowDesktopSwitcher(
  BuildContext context, {
  required List<FlowTaskCard> cards,
  required double cardAspect,
  required Map<String, Rect> Function() origins,
  required void Function(FlowTaskCard card, Rect rect) onOpen,
  void Function(FlowTaskCard card)? onClose,
  String title = '',
  String closeLabel = '',
}) {
  final closed = Completer<void>();
  unawaited(
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        // Text needs a Material above it (without one it shows the
        // framework's yellow-underlined fallback style).
        pageBuilder: (context, _, _) => Material(
          type: MaterialType.transparency,
          child: FlowDesktopSwitcher(
            cards: cards,
            cardAspect: cardAspect,
            origins: origins,
            onOpen: onOpen,
            onClose: onClose,
            title: title,
            closeLabel: closeLabel,
            onGone: () {
              if (!closed.isCompleted) {
                closed.complete();
              }
            },
          ),
        ),
      ),
    ),
  );
  return closed.future;
}

class FlowDesktopSwitcher extends StatefulWidget {
  const FlowDesktopSwitcher({
    super.key,
    required this.cards,
    required this.cardAspect,
    required this.origins,
    required this.onOpen,
    required this.onGone,
    this.onClose,
    this.title = '',
    this.closeLabel = '',
  });

  final List<FlowTaskCard> cards;
  final double cardAspect;
  final Map<String, Rect> Function() origins;
  final void Function(FlowTaskCard card, Rect rect) onOpen;
  final void Function(FlowTaskCard card)? onClose;
  final String title;
  final String closeLabel;

  /// The switcher has gone (its cards back in the stack, or one opened).
  final VoidCallback onGone;

  /// How long the cards take to lift out or settle back.
  static const Duration motion = Duration(milliseconds: 300);

  /// The grid for [count] cards of [aspect] (width / height) in [area]:
  /// as large as fits without scrolling, else no smaller than a card can
  /// be read at, scrolling. Rects are each card's picture; its name goes
  /// under it ([labelHeight]).
  static FlowGridLayout layout(Size area, int count, double aspect) {
    const gap = 28.0;
    const labelHeight = 30.0;
    final maxWidth = aspect >= 1 ? 440.0 : 230.0;
    final minWidth = aspect >= 1 ? 220.0 : 120.0;
    if (count == 0 || area.isEmpty) {
      return const FlowGridLayout([], 0, Size.zero);
    }
    double widthFor(int columns) =>
        math.min(maxWidth, (area.width - (columns - 1) * gap) / columns);
    double heightFor(int columns, double width) {
      final rows = (count / columns).ceil();
      return rows * (width / aspect + labelHeight) + (rows - 1) * gap;
    }

    var columns = 0;
    for (var c = 1; c <= count; c++) {
      final width = widthFor(c);
      if (width < minWidth) {
        break;
      }
      if (heightFor(c, width) <= area.height) {
        columns = c;
        break;
      }
    }
    if (columns == 0) {
      // Too many to fit: as many to a row as stay readable, scrolling.
      columns = 1;
      while (columns < count && widthFor(columns + 1) >= minWidth) {
        columns++;
      }
    }
    final width = widthFor(columns);
    final height = width / aspect;
    final rows = (count / columns).ceil();
    final total = heightFor(columns, width);
    final top = math.max(0.0, (area.height - total) / 2);
    final rects = <Rect>[];
    for (var row = 0; row < rows; row++) {
      final inRow = math.min(columns, count - row * columns);
      final rowWidth = inRow * width + (inRow - 1) * gap;
      final left = (area.width - rowWidth) / 2;
      for (var i = 0; i < inRow; i++) {
        rects.add(
          Rect.fromLTWH(
            left + i * (width + gap),
            top + row * (height + labelHeight + gap),
            width,
            height,
          ),
        );
      }
    }
    return FlowGridLayout(rects, columns, Size(area.width, top + total));
  }

  @override
  State<FlowDesktopSwitcher> createState() => _FlowDesktopSwitcherState();
}

/// Where [FlowDesktopSwitcher] puts its cards.
class FlowGridLayout {
  const FlowGridLayout(this.rects, this.columns, this.size);

  /// Each card's picture, in the grid's own coordinates.
  final List<Rect> rects;
  final int columns;

  /// The whole grid (taller than the area when it scrolls).
  final Size size;
}

class _FlowDesktopSwitcherState extends State<FlowDesktopSwitcher> {
  late final List<FlowTaskCard> _cards = List.of(widget.cards);

  /// Out of the stack (true) or in it (false: arriving and leaving).
  bool _shown = false;
  bool _leaving = false;

  /// A card being opened: the rest fade while it stays.
  String? _opening;

  /// Cards fading out after their window was closed.
  final _removing = <String>{};

  String? _hovered;
  int _selected = 0;
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'flow-desktop-switcher');

  /// The stack's rects, in this overlay's coordinates.
  Map<String, Rect> _origins = const {};

  static const _top = 56.0;
  static const _side = 56.0;
  static const _bottom = 48.0;

  @override
  void initState() {
    super.initState();
    _origins = widget.origins();
    // One frame in the stack's places, then out to the grid.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _shown = true);
        _focus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Duration get _motion =>
      flowReduceMotion(context) ? Duration.zero : FlowDesktopSwitcher.motion;

  Future<void> _dismiss() async {
    if (_leaving) {
      return;
    }
    // Back to where the stack is now (closing windows here moved it).
    setState(() {
      _origins = widget.origins();
      _leaving = true;
      _shown = false;
    });
    await Future<void>.delayed(_motion);
    _gone();
  }

  void _gone() {
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
    widget.onGone();
  }

  Future<void> _open(FlowTaskCard card, Rect rect) async {
    if (_leaving || card.closing) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _opening = card.key;
      _leaving = true;
    });
    await Future<void>.delayed(
      flowReduceMotion(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
    );
    _gone();
    widget.onOpen(card, rect);
  }

  Future<void> _close(FlowTaskCard card) async {
    final onClose = widget.onClose;
    if (onClose == null || _removing.contains(card.key)) {
      return;
    }
    onClose(card);
    setState(() => _removing.add(card.key));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) {
      return;
    }
    setState(() {
      _removing.remove(card.key);
      _cards.removeWhere((c) => c.key == card.key);
      _selected = _selected.clamp(0, math.max(0, _cards.length - 1));
    });
    if (_cards.isEmpty) {
      unawaited(_dismiss());
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, int columns) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      unawaited(_dismiss());
      return KeyEventResult.handled;
    }
    if (_cards.isEmpty) {
      return KeyEventResult.ignored;
    }
    final last = _cards.length - 1;
    int? next;
    if (key == LogicalKeyboardKey.arrowRight) {
      next = _selected + 1;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      next = _selected - 1;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      next = _selected + columns;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      next = _selected - columns;
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      final card = _cards[_selected];
      unawaited(_open(card, _lastRects[card.key] ?? Rect.zero));
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      unawaited(_close(_cards[_selected]));
      return KeyEventResult.handled;
    }
    if (next == null) {
      return KeyEventResult.ignored;
    }
    setState(() => _selected = next!.clamp(0, last));
    return KeyEventResult.handled;
  }

  /// Each card's rect on screen as last laid out, for opening it.
  final _lastRects = <String, Rect>{};

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final area = Size(
          math.max(0, size.width - 2 * _side),
          math.max(0, size.height - _top - _bottom - media.padding.vertical),
        );
        final grid = FlowDesktopSwitcher.layout(
          area,
          _cards.length,
          widget.cardAspect,
        );
        final scrollOffset = _scroll.hasClients ? _scroll.offset : 0.0;
        final gridTop = _top + media.padding.top;
        final children = <Widget>[];
        for (var index = _cards.length - 1; index >= 0; index--) {
          final card = _cards[index];
          final inGrid = grid.rects[index].shift(Offset(_side, 0));
          // The stack is on the page, which does not scroll with the grid.
          final origin =
              _origins[card.key]?.shift(Offset(0, scrollOffset - gridTop)) ??
              Rect.fromCenter(
                center: inGrid.center,
                width: inGrid.width * 0.6,
                height: inGrid.height * 0.6,
              );
          final opening = _opening == card.key;
          final rect = _shown || opening ? inGrid : origin;
          _lastRects[card.key] = inGrid.shift(
            Offset(0, gridTop - scrollOffset),
          );
          // Cards the stack does not show fade in and out where they are.
          final visible =
              !_removing.contains(card.key) &&
              (_opening == null || opening) &&
              (_shown || _origins.containsKey(card.key));
          children.add(
            AnimatedPositioned(
              key: ValueKey(card.key),
              duration: _motion,
              curve: _leaving ? Curves.easeInCubic : Curves.easeOutCubic,
              left: rect.left,
              top: rect.top,
              width: rect.width,
              // The name under the picture opens it too.
              height: rect.height + _GridCard.labelHeight,
              child: AnimatedOpacity(
                duration: _removing.contains(card.key) || _opening != null
                    ? const Duration(milliseconds: 160)
                    : _motion,
                opacity: visible ? 1 : 0,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 200),
                  scale: _removing.contains(card.key) ? 0.9 : 1,
                  child: _GridCard(
                    card: card,
                    showLabel: _shown && !_leaving,
                    hovered: _hovered == card.key,
                    selected: _selected == index && _shown,
                    closeLabel: widget.closeLabel,
                    onHover: (inside) => setState(() {
                      if (inside) {
                        _hovered = card.key;
                        _selected = index;
                      } else if (_hovered == card.key) {
                        _hovered = null;
                      }
                    }),
                    onTap: () =>
                        unawaited(_open(card, _lastRects[card.key] ?? inGrid)),
                    onClose: widget.onClose == null || card.closing
                        ? null
                        : () => unawaited(_close(card)),
                  ),
                ),
              ),
            ),
          );
        }
        return Focus(
          focusNode: _focus,
          onKeyEvent: (node, event) => _onKey(node, event, grid.columns),
          // No title over the grid (the page's own showed through the dim
          // under it, two titles in one place); screen readers still get it.
          child: Stack(
            children: [
              if (widget.title.isNotEmpty)
                Semantics(
                  namesRoute: true,
                  scopesRoute: true,
                  explicitChildNodes: true,
                  label: widget.title,
                  child: const SizedBox.shrink(),
                ),
              // The page behind, dimmed; a click there goes back.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(_dismiss()),
                  child: AnimatedOpacity(
                    duration: _motion,
                    opacity: _shown && _opening == null ? 1 : 0,
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: colors.dark ? 0.55 : 0.42,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: gridTop,
                bottom: _bottom + media.padding.bottom,
                child: SingleChildScrollView(
                  controller: _scroll,
                  clipBehavior: Clip.none,
                  child: SizedBox(
                    width: size.width,
                    height: math.max(grid.size.height, area.height),
                    // A click between the cards goes back too.
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () => unawaited(_dismiss()),
                      child: Stack(clipBehavior: Clip.none, children: children),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A window in the grid: its picture, and its icon and name under it.
class _GridCard extends StatelessWidget {
  const _GridCard({
    required this.card,
    required this.showLabel,
    required this.hovered,
    required this.selected,
    required this.closeLabel,
    required this.onHover,
    required this.onTap,
    this.onClose,
  });

  /// Room under the picture for the icon and name.
  static const double labelHeight = 30;

  final FlowTaskCard card;
  final bool showLabel;
  final bool hovered;
  final bool selected;
  final String closeLabel;
  final void Function(bool inside) onHover;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    const radius = 14.0;
    final ring = hovered || selected;
    return MouseRegion(
      cursor: card.closing
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: Semantics(
        button: !card.closing,
        label: card.closing
            ? '${card.title}, ${card.closingLabel}'
            : card.title,
        child: GestureDetector(
          // The name is drawn without taking the pointer; the card does.
          behavior: HitTestBehavior.opaque,
          onTap: card.closing ? null : onTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                bottom: labelHeight,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  scale: hovered ? 1.025 : 1,
                  child: RepaintBoundary(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x40000000),
                            blurRadius: 28,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (card.snapshot != null)
                              FlowCardPicture(snapshot: card.snapshot!)
                            else
                              ColoredBox(
                                color: card.hue,
                                child: Center(
                                  child: FlowAppIcon(
                                    label: card.title,
                                    icon: card.icon,
                                    hue: card.hue,
                                    size: 56,
                                    onColor: true,
                                  ),
                                ),
                              ),
                            if (card.closing)
                              const ColoredBox(
                                color: Color(0x73000000),
                                child: Center(
                                  child: CupertinoActivityIndicator(
                                    color: Colors.white,
                                    radius: 11,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // The ring sits outside the picture, as a selection does.
              Positioned.fill(
                left: -4,
                top: -4,
                right: -4,
                bottom: labelHeight - 4,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: ring ? 1 : 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius + 4),
                        border: Border.all(
                          color: colors.scheme.primary,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (onClose != null)
                Positioned(
                  left: 8,
                  top: 8,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: hovered ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !hovered,
                      child: Semantics(
                        button: true,
                        label: closeLabel,
                        child: Tooltip(
                          message: closeLabel,
                          waitDuration: const Duration(milliseconds: 600),
                          child: GestureDetector(
                            onTap: onClose,
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: const Color(0xF22C2C2E),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0x33FFFFFF),
                                ),
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // Icon and name under the picture.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 24,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: showLabel ? 1 : 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FlowAppIcon(
                          label: card.title,
                          icon: card.icon,
                          hue: card.hue,
                          size: 20,
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            card.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
