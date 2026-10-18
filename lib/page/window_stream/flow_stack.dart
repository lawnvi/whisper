import 'dart:math' as math;

/// How windows lie in a stack, the same small on the Flow page and full
/// screen in the switcher, so one grows into the other: the window in
/// front, newer ones to its right, older ones tucked under it to the left.
///
/// To the right, cards keep an even spacing a little under a card's width:
/// a card leaving to the right stays on top of the one after it until it is
/// off the screen, and no gap ever opens. To the left the one in front
/// covers most of the next (about a quarter of it shows, then less and
/// less: about 8%, 4%, 3%), so with enough windows three or four are in
/// view, the deepest against the screen's edge. The two sides meet smoothly, so a swipe moves every card
/// continuously: one sliding under the front slows down quickly, but
/// without a jolt.
abstract final class FlowStack {
  /// Spacing to the right, in card widths.
  static const double _spacing = 0.9;

  /// To the left: a slow part that spaces the cards further back
  /// ([_far] card widths in all, each next strip [_ratio] of the last) and
  /// a quick one that takes the front card's speed down to it; their
  /// slopes add up to [_spacing] at the front.
  static const double _far = 0.37;
  static const double _farRate = 0.6;
  static const double _quickRate = 6;
  static const double _quick = (_spacing - _far * _farRate) / _quickRate;

  /// Horizontal offset, in card widths, of a card [d] places from the one
  /// in front (positive: newer, to the right).
  static double offset(double d) {
    if (d >= 0) {
      return d * _spacing;
    }
    return -_far * (1 - math.exp(_farRate * d)) -
        _quick * (1 - math.exp(_quickRate * d));
  }

  /// How far left the stack can reach, in card widths (negative).
  static const double _leftmost = -(_far + _quick);

  /// The place whose offset is [offset] (inverse of [offset]).
  static double placeOf(double offset) {
    if (offset >= 0) {
      return offset / _spacing;
    }
    if (offset <= _leftmost + 1e-4) {
      return -12;
    }
    // Monotonic: halve the interval until it is tight.
    var low = -12.0;
    var high = 0.0;
    for (var i = 0; i < 40; i++) {
      final middle = (low + high) / 2;
      if (FlowStack.offset(middle) < offset) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return (low + high) / 2;
  }

  /// Card widths moved per place, at place [d].
  static double slope(double d) => d >= 0
      ? _spacing
      : _far * _farRate * math.exp(_farRate * d) +
            _quick * _quickRate * math.exp(_quickRate * d);

  /// Older cards are a touch smaller and darker, as if further back: 2.5%
  /// less per layer, so the stack's edges step down gently. (The front card
  /// is never pushed into this: pulled past an end, the whole row slides
  /// instead.)
  static double scale(double d) => d >= 0 ? 1 : 1 - 0.025 * math.min(-d, 3);

  static double shade(double d) => d >= 0 ? 0 : math.min(-d, 3) * 0.06;

  /// The deepest layer drawn at rest; cards further back fade out.
  static const int deepestShown = 4;

  /// From the left edge of the deepest card a stack of [count] shows, to
  /// the front card's centre, in card widths. [count] may be fractional
  /// while a card is going away, so the stack closes up smoothly.
  static double reachToCentre(double count) {
    if (count <= 1) {
      return 0.5;
    }
    final deepest = -math.min(count - 1, deepestShown.toDouble());
    return -offset(deepest) + scale(deepest) / 2;
  }

  /// Pulled [beyond] an end (card widths, signed): how far the row goes,
  /// harder the further, never more than 0.6, like a rubber band.
  static double rubber(double beyond) {
    final give = (1 - 1 / (beyond.abs() * 0.55 / _limit + 1)) * _limit;
    return beyond < 0 ? -give : give;
  }

  /// The pull that moves the row [give] past an end (inverse of [rubber]).
  static double pullFor(double give) {
    final left = 1 - math.min(give.abs() / _limit, 0.99);
    final pull = (1 / left - 1) * _limit / 0.55;
    return give < 0 ? -pull : pull;
  }

  /// The furthest the row ever goes past an end, in card widths.
  static const double maxBeyond = _limit;

  static const double _limit = 0.6;
}
