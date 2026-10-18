import '../core/window_input_event.dart';

/// Turns the scalar arguments of the native input callback (see
/// `wsn_input_callback` in window_stream_native.h) into a [WindowInputEvent].
abstract final class NativeInputDecoder {
  static const int _pointerDown = 1;
  static const int _pointerMove = 2;
  static const int _pointerUp = 3;
  static const int _scroll = 4;
  static const int _keyDown = 5;
  static const int _keyUp = 6;
  static const int _text = 7;
  static const int _pointerCancel = 8;

  static WindowInputEvent? decode({
    required int kind,
    required int code,
    required int modifiers,
    required double x,
    required double y,
    required double dx,
    required double dy,
    required int phase,
    String? text,
  }) {
    switch (kind) {
      case _pointerDown:
      case _pointerMove:
      case _pointerUp:
      case _pointerCancel:
        return PointerInput(
          action: switch (kind) {
            _pointerDown => PointerAction.down,
            _pointerMove => PointerAction.move,
            _pointerUp => PointerAction.up,
            _ => PointerAction.cancel,
          },
          x: x,
          y: y,
          button: switch (code) {
            1 => PointerButton.secondary,
            2 => PointerButton.middle,
            _ => PointerButton.primary,
          },
        );
      case _scroll:
        return ScrollInput(
          x: x,
          y: y,
          dx: dx,
          dy: dy,
          phase: scrollPhase(phase & 0xff),
          momentumPhase: scrollPhase((phase >> 8) & 0xff),
          precise: phase & (1 << 16) != 0,
        );
      case _keyDown:
      case _keyUp:
        return KeyInput(
          down: kind == _keyDown,
          macKeyCode: code,
          characters: text,
          modifiers: modifiers,
          repeat: phase & 1 != 0,
        );
      case _text:
        if (text == null || text.isEmpty) {
          return null;
        }
        return TextInput(text, paste: code == 1);
    }
    return null;
  }

  /// NSEvent.Phase is a bit mask: began 1, stationary 2, changed 4,
  /// ended 8, cancelled 16, mayBegin 32.
  static ScrollPhase scrollPhase(int bits) {
    if (bits & 1 != 0) return ScrollPhase.began;
    if (bits & 4 != 0) return ScrollPhase.changed;
    if (bits & 8 != 0) return ScrollPhase.ended;
    if (bits & 16 != 0) return ScrollPhase.cancelled;
    if (bits & 2 != 0) return ScrollPhase.stationary;
    if (bits & 32 != 0) return ScrollPhase.mayBegin;
    return ScrollPhase.none;
  }
}

/// Scalar form of a [WindowInputEvent], as native code and the `/window`
/// input packet carry it (the inverse of [NativeInputDecoder]).
class EncodedInput {
  const EncodedInput({
    required this.kind,
    this.code = 0,
    this.modifiers = 0,
    this.phase = 0,
    this.x = 0,
    this.y = 0,
    this.dx = 0,
    this.dy = 0,
    this.text,
  });

  final int kind;
  final int code;
  final int modifiers;
  final int phase;
  final double x;
  final double y;
  final double dx;
  final double dy;
  final String? text;

  static int _phaseBits(ScrollPhase phase) => switch (phase) {
    ScrollPhase.none => 0,
    ScrollPhase.began => 1,
    ScrollPhase.stationary => 2,
    ScrollPhase.changed => 4,
    ScrollPhase.ended => 8,
    ScrollPhase.cancelled => 16,
    ScrollPhase.mayBegin => 32,
  };

  /// Null for events that have no scalar form (e.g. navigation).
  static EncodedInput? of(WindowInputEvent event) {
    switch (event) {
      case PointerInput():
        return EncodedInput(
          kind: switch (event.action) {
            PointerAction.down => 1,
            PointerAction.move => 2,
            PointerAction.up => 3,
            PointerAction.cancel => 8,
          },
          code: event.button.index,
          x: event.x,
          y: event.y,
        );
      case ScrollInput():
        return EncodedInput(
          kind: 4,
          x: event.x,
          y: event.y,
          dx: event.dx,
          dy: event.dy,
          phase:
              _phaseBits(event.phase) |
              _phaseBits(event.momentumPhase) << 8 |
              (event.precise ? 1 << 16 : 0),
        );
      case KeyInput():
        return EncodedInput(
          kind: event.down ? 5 : 6,
          code: event.macKeyCode,
          modifiers: event.modifiers,
          phase: event.repeat ? 1 : 0,
          text: event.characters,
        );
      case TextInput():
        return EncodedInput(
          kind: 7,
          code: event.paste ? 1 : 0,
          text: event.text,
        );
      case NavigationInput():
        return null;
    }
  }
}
