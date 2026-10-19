import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'flow_app_icon.dart';
import 'flow_space_theme.dart';
import 'flow_stack.dart';

/// One card of the recents deck.
class FlowTaskCard {
  const FlowTaskCard({
    required this.key,
    required this.title,
    required this.hue,
    this.snapshot,
    this.icon,
    this.badge,
    this.closing = false,
    this.closingLabel = '',
  });

  final String key;
  final String title;
  final Color hue;
  final Uint8List? snapshot;
  final Uint8List? icon;

  /// Short status shown on the card, e.g. "On desktop".
  final String? badge;

  /// Its window was asked to close and its device has not said how that
  /// went: the card dims under a spinner and cannot be opened meanwhile.
  final bool closing;
  final String closingLabel;
}

/// Recent tasks as a stack: the newest in front, older ones tucked under
/// it. A click on the stack shows every window ([onShowAll]: the phone's
/// switcher on a touch screen, a grid on a desktop), each growing from
/// where it lies here; without [onShowAll], hovering fans the cards out
/// into a row and a click on one opens it.
class FlowRecentsDeck extends StatefulWidget {
  const FlowRecentsDeck({
    super.key,
    required this.cards,
    required this.onOpen,
    this.onClose,
    this.closeLabel = '',
    this.cardWidth = 168,
    this.cardAspect = 9 / 19.5,
    this.maxVisible = 7,
    this.onShowAll,
    this.curvedStack = false,
  });

  /// Stacked on the switcher's curve ([FlowStack], touch screens: the
  /// switcher grows straight out of it), else diagonally (a mouse).
  final bool curvedStack;

  /// Touch screens: a tap on the stack shows every window full screen
  /// (the switcher) instead of fanning the stack out. [cards] tells each
  /// card's global rect, now: the switcher grows out of them and closes
  /// back into them. The stack hides until the returned future completes.
  final Future<void> Function(Map<String, Rect> Function() cards)? onShowAll;

  final List<FlowTaskCard> cards;
  final void Function(FlowTaskCard card, Rect globalRect) onOpen;

  /// Closes the card's window or task on its device.
  final void Function(FlowTaskCard card)? onClose;
  final String closeLabel;
  final double cardWidth;

  /// Width / height of a card (phone screens are tall).
  final double cardAspect;
  final int maxVisible;

  @override
  State<FlowRecentsDeck> createState() => _FlowRecentsDeckState();
}

class _FlowRecentsDeckState extends State<FlowRecentsDeck> {
  bool _expanded = false;
  int? _hovered;

  /// A mouse is over the deck (it fanned out on hover, not on a tap).
  bool _pointerHovering = false;
  final _cardKeys = <String, GlobalKey>{};

  double get _cardHeight => widget.cardWidth / widget.cardAspect;

  /// Cards that show in the stack; the rest wait behind.
  static const _shownInStack = 5;

  /// Touch screens stack like the switcher they open into.
  bool get _switcherStyle => widget.curvedStack;

  /// The diagonal stack (mouse): how far each card behind steps right and up.
  static const _stepX = 22.0;
  static const _rise = 13.0;

  /// The switcher is up, grown out of these cards.
  bool _presented = false;

  GlobalKey _keyFor(String id) => _cardKeys.putIfAbsent(id, GlobalKey.new);

  /// Where [key]'s card is on screen, as drawn (scaled with the stack).
  Rect _rectOf(String key) {
    final box = _keyFor(key).currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return Rect.zero;
    }
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  void _open(FlowTaskCard card) => widget.onOpen(card, _rectOf(card.key));

  Future<void> _present(
    Future<void> Function(Map<String, Rect> Function()) showAll,
  ) async {
    // Where the cards are, asked again as the switcher closes: closing a
    // window there moves the rest here too.
    Map<String, Rect> rects() => {
      for (final card in widget.cards.take(
        math.min(widget.maxVisible, _shownInStack),
      ))
        card.key: _rectOf(card.key),
    };
    // The cards are the switcher's now; they come back once it has closed
    // into them.
    setState(() => _presented = true);
    await showAll(rects);
    if (mounted) {
      setState(() => _presented = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cards = widget.cards.take(widget.maxVisible).toList();
    if (cards.isEmpty) {
      return const SizedBox.shrink();
    }
    final reduceMotion = flowReduceMotion(context);
    const spacing = 16.0;
    final spreadWidth =
        cards.length * widget.cardWidth + (cards.length - 1) * spacing;
    final shownCount = math.min(cards.length, _shownInStack);
    // Touch: the switcher's stack, its deepest card against the deck's
    // left edge. Mouse: a diagonal stack that fans out to the right, the way
    // it unfolds on hover.
    final stackedWidth = _switcherStyle
        ? widget.cardWidth * (FlowStack.reachToCentre(shownCount * 1.0) + 0.5)
        : widget.cardWidth + (shownCount - 1) * _stepX;
    final width = _expanded ? spreadWidth : stackedWidth;
    final height =
        _cardHeight + 24 + (_switcherStyle ? 0 : (shownCount - 1) * _rise);

    return TapRegion(
      onTapOutside: (_) {
        if (_expanded && !_pointerHovering) {
          setState(() => _expanded = false);
        }
      },
      child: FocusableActionDetector(
        onShowHoverHighlight: (value) => setState(() {
          _pointerHovering = value;
          // With every window a click away, the stack stays put (fanning
          // out pushed the later ones past where a mouse could reach).
          _expanded = value && widget.onShowAll == null;
          if (!value) {
            _hovered = null;
          }
        }),
        onShowFocusHighlight: (value) {
          if (value && widget.onShowAll == null) {
            setState(() => _expanded = true);
          }
        },
        child: AnimatedContainer(
          duration: reduceMotion
              ? Duration.zero
              : FlowSpaceTokens.springDuration,
          curve: const SpringCurve(),
          width: width,
          height: height,
          // Gone at once while the switcher has the cards (it grows out of
          // exactly this), back once it has closed into it.
          child: AnimatedOpacity(
            duration: _presented || reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 60),
            opacity: _presented ? 0 : 1,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Back to front, so the newest card is on top while stacked.
                for (var index = cards.length - 1; index >= 0; index--)
                  _buildCard(context, cards, index, spacing, reduceMotion),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context,
    List<FlowTaskCard> cards,
    int index,
    double spacing,
    bool reduceMotion,
  ) {
    final card = cards[index];
    // Stacked: the front card on the right, the older ones to its left on
    // the switcher's curve, so the switcher grows straight out of this.
    final d = -index.toDouble();
    final shownCount = math.min(cards.length, _shownInStack);
    // The front card's centre, as far from the deck's left edge as the
    // deepest card shown reaches (scaled cards shrink about their centres).
    final reach = FlowStack.reachToCentre(shownCount * 1.0) - 0.5;
    final step = math.min(index, _shownInStack).toDouble();
    // The diagonal stack: each card behind steps right and up.
    final base = 12.0 + (_switcherStyle ? 0 : (shownCount - 1) * _rise);
    final left = _expanded
        ? index * (widget.cardWidth + spacing)
        : _switcherStyle
        ? (reach + FlowStack.offset(d)) * widget.cardWidth
        : step * _stepX;
    final scale = _expanded
        ? (_hovered == index ? 1.035 : 1.0)
        : _switcherStyle
        ? FlowStack.scale(d)
        : math.pow(0.97, step).toDouble();
    final top = _expanded
        ? base - (_hovered == index ? 8.0 : 0.0)
        : _switcherStyle
        ? base
        : base - step * _rise;
    final shade = _expanded
        ? 0.0
        : _switcherStyle
        ? FlowStack.shade(d)
        : step * 0.07;
    final shown = _expanded || index < _shownInStack;
    final delay = _expanded ? index : cards.length - 1 - index;
    final duration = reduceMotion
        ? Duration.zero
        : FlowSpaceTokens.springDuration + FlowSpaceTokens.staggerStep * delay;
    return AnimatedPositioned(
      key: ValueKey(card.key),
      duration: duration,
      curve: const SpringCurve(),
      left: left,
      top: top,
      width: widget.cardWidth,
      height: _cardHeight,
      child: AnimatedScale(
        duration: reduceMotion ? Duration.zero : FlowSpaceTokens.quickDuration,
        curve: const SpringCurve(FlowSpaceTokens.snappySpring, 0.3),
        scale: scale,
        alignment: _expanded
            ? Alignment.bottomCenter
            : _switcherStyle
            ? Alignment.center
            : Alignment.bottomLeft,
        child: AnimatedOpacity(
          duration: duration,
          opacity: shown ? 1 : 0,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = index),
            onExit: (_) => setState(() {
              if (_hovered == index) _hovered = null;
            }),
            child: _DeckCard(
              key: _keyFor(card.key),
              card: card,
              shade: shade,
              // Pointed at, the stack lifts its front card.
              elevated: _expanded
                  ? _hovered == index
                  : _pointerHovering && index == 0,
              closeLabel: widget.closeLabel,
              // The close button shows on a fanned-out card: hovered with
              // a mouse, always on a touch screen.
              onClose:
                  widget.onClose == null ||
                      card.closing ||
                      !_expanded ||
                      (_pointerHovering && _hovered != index)
                  ? null
                  : () => widget.onClose!(card),
              onTap: () {
                if (card.closing && _expanded) {
                  return;
                }
                HapticFeedback.selectionClick();
                final showAll = widget.onShowAll;
                // A single window on a desktop opens at once.
                if (!_expanded &&
                    showAll != null &&
                    (widget.curvedStack || cards.length > 1)) {
                  unawaited(_present(showAll));
                  return;
                }
                if (!_expanded && cards.length > 1) {
                  setState(() => _expanded = true);
                  return;
                }
                _open(card);
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _DeckCard extends StatelessWidget {
  const _DeckCard({
    super.key,
    required this.card,
    required this.onTap,
    required this.elevated,
    required this.closeLabel,
    this.onClose,
    this.shade = 0,
  });

  final FlowTaskCard card;
  final VoidCallback onTap;
  final bool elevated;

  /// How much darker than the front card (cards further back).
  final double shade;
  final String closeLabel;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final shape = FlowSpaceTokens.card(22);
    return Semantics(
      button: !card.closing,
      label: card.closing ? '${card.title}, ${card.closingLabel}' : card.title,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: FlowSpaceTokens.quickDuration,
          decoration: ShapeDecoration(
            shape: shape,
            shadows: elevated
                ? colors.liftedShadow(card.hue)
                : colors.cardShadow,
            color: colors.raised,
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (card.snapshot != null)
                  FlowCardPicture(snapshot: card.snapshot!)
                else
                  _Placeholder(card: card),
                // Legibility scrim for the title.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.55, 1],
                      colors: [Color(0x00000000), Color(0x99000000)],
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Row(
                    children: [
                      FlowAppIcon(
                        label: card.title,
                        icon: card.icon,
                        hue: card.hue,
                        size: 26,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
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
                Positioned(
                  top: 8,
                  right: 8,
                  child: AnimatedScale(
                    duration: FlowSpaceTokens.quickDuration,
                    curve: Curves.easeOutBack,
                    scale: onClose == null ? 0 : 1,
                    child: Semantics(
                      button: true,
                      label: closeLabel,
                      child: GestureDetector(
                        onTap: onClose,
                        child: FlowGlass(
                          radius: FlowSpaceTokens.capsuleRadius,
                          tint: Colors.black.withValues(alpha: 0.45),
                          child: const SizedBox.square(
                            dimension: 26,
                            child: Icon(
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
                IgnorePointer(
                  child: AnimatedContainer(
                    duration: FlowSpaceTokens.quickDuration,
                    color: Colors.black.withValues(alpha: shade),
                  ),
                ),
                // Built only while closing: a spinner kept at zero opacity
                // still turned, and redrew the page every frame.
                IgnorePointer(
                  child: AnimatedSwitcher(
                    duration: FlowSpaceTokens.quickDuration,
                    child: card.closing
                        ? const ColoredBox(
                            color: Color(0x73000000),
                            child: Center(
                              child: CupertinoActivityIndicator(
                                color: Colors.white,
                                radius: 11,
                              ),
                            ),
                          )
                        : const SizedBox.expand(),
                  ),
                ),
                if (card.badge != null)
                  Positioned(
                    top: 10,
                    left: 10,
                    child: FlowGlass(
                      radius: FlowSpaceTokens.capsuleRadius,
                      tint: Colors.black.withValues(alpha: 0.35),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: FlowSpaceTokens.live,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            card.badge!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Card face when no snapshot exists: the app's colour with its icon.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.card});

  final FlowTaskCard card;

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(card.hue);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            hsl.withLightness((hsl.lightness + 0.12).clamp(0, 1)).toColor(),
            hsl.withLightness((hsl.lightness - 0.18).clamp(0, 1)).toColor(),
          ],
        ),
      ),
      child: Center(
        child: FlowAppIcon(
          label: card.title,
          icon: card.icon,
          hue: card.hue,
          size: 64,
          onColor: true,
        ),
      ),
    );
  }
}

/// A window's picture filling its card, as a phone's recents show apps.
/// A picture of another shape (a wide Mac window on an upright card, until
/// it has been open here) shows from its top left, where Mac apps keep
/// their lists and text.
class FlowCardPicture extends StatelessWidget {
  const FlowCardPicture({super.key, required this.snapshot});

  final Uint8List snapshot;

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      snapshot,
      fit: BoxFit.cover,
      alignment: Alignment.topLeft,
      gaplessPlayback: true,
    );
  }
}
