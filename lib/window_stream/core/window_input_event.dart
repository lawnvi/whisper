/// Input captured in a streamed window, in source-independent form.
/// Coordinates are fractions of the video (0–1, origin top-left), so each
/// source maps them onto its own screen without knowing the window size.
sealed class WindowInputEvent {
  const WindowInputEvent();
}

enum PointerAction { down, move, up, cancel }

enum PointerButton { primary, secondary, middle }

class PointerInput extends WindowInputEvent {
  const PointerInput({
    required this.action,
    required this.x,
    required this.y,
    this.button = PointerButton.primary,
  });

  final PointerAction action;
  final double x;
  final double y;
  final PointerButton button;
}

/// How trackpad and wheel scrolling reaches the app.
enum ScrollMode {
  /// Scroll events: right for lists and web pages.
  wheel,

  /// A synthesized finger drag: right for vertical pagers (short-video apps)
  /// that ignore scroll events.
  drag,
}

/// Gesture phase of a trackpad scroll, mirroring NSEvent.Phase.
enum ScrollPhase {
  none,
  began,
  changed,
  ended,
  cancelled,
  mayBegin,
  stationary,
}

class ScrollInput extends WindowInputEvent {
  const ScrollInput({
    required this.x,
    required this.y,
    required this.dx,
    required this.dy,
    this.phase = ScrollPhase.none,
    this.momentumPhase = ScrollPhase.none,
    this.precise = false,
  });

  final double x;
  final double y;

  /// Content movement in points; positive dy scrolls content down
  /// (finger moving down on a trackpad with natural scrolling).
  final double dx;
  final double dy;
  final ScrollPhase phase;
  final ScrollPhase momentumPhase;

  /// Trackpad (pixel) deltas rather than mouse-wheel lines.
  final bool precise;

  bool get gestureEnded =>
      (phase == ScrollPhase.ended || phase == ScrollPhase.cancelled) &&
          momentumPhase == ScrollPhase.none ||
      momentumPhase == ScrollPhase.ended ||
      momentumPhase == ScrollPhase.cancelled;
}

abstract final class InputModifiers {
  static const int shift = 0x1;
  static const int control = 0x2;
  static const int option = 0x4;
  static const int command = 0x8;
  static const int capsLock = 0x10;
  static const int function = 0x20;
}

class KeyInput extends WindowInputEvent {
  const KeyInput({
    required this.down,
    required this.macKeyCode,
    this.characters,
    this.modifiers = 0,
    this.repeat = false,
  });

  final bool down;

  /// Hardware key code as reported by the receiving Mac.
  final int macKeyCode;

  /// Characters the key produced with the current layout, if any.
  final String? characters;
  final int modifiers;
  final bool repeat;

  bool has(int modifier) => modifiers & modifier != 0;
}

/// Committed text (IME result or paste).
class TextInput extends WindowInputEvent {
  const TextInput(this.text, {this.paste = false});

  final String text;

  /// Came from ⌘V: replace the source clipboard and paste.
  final bool paste;
}

/// Semantic actions that every source supports in its own way.
enum NavigationAction { back, home, recents }

class NavigationInput extends WindowInputEvent {
  const NavigationInput(this.action);

  final NavigationAction action;
}
