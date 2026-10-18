import 'dart:typed_data';

import '../../core/window_input_event.dart';
import '../android_keycodes.dart';
import 'scrcpy_protocol.dart';

/// A control message, optionally sent after a delay (synthesized swipes).
class ScheduledControl {
  const ScheduledControl(this.bytes, {this.delay = Duration.zero});

  final Uint8List bytes;
  final Duration delay;
}

/// Turns window input into scrcpy control messages for one stream. Keeps the
/// small amount of state that needs: the frame size, an in-progress drag and
/// the clipboard sequence.
class ScrcpyInputMapper {
  ScrcpyInputMapper({this.scrollMode = ScrollMode.wheel});

  ScrollMode scrollMode;
  int frameWidth = 0;
  int frameHeight = 0;
  int _clipboardSequence = 1;

  bool _dragging = false;
  double _dragX = 0;
  double _dragY = 0;

  /// One wheel notch is about this fraction of the screen height.
  static const double notchFraction = 0.066;
  static const double wheelSwipeFraction = 0.42;
  static const int wheelSwipeSteps = 8;
  static const Duration wheelSwipeStep = Duration(milliseconds: 14);

  bool get hasFrame => frameWidth > 0 && frameHeight > 0;

  List<ScheduledControl> map(WindowInputEvent event) {
    return switch (event) {
      PointerInput() => _pointer(event),
      ScrollInput() => _scroll(event),
      KeyInput() => _key(event),
      TextInput() => _text(event.text, paste: event.paste),
      NavigationInput() => _navigation(event.action),
    };
  }

  int _px(double fraction, int size) =>
      (fraction.clamp(0.0, 1.0) * (size - 1)).round();

  Uint8List _touch(int action, double x, double y) {
    return ScrcpyControl.injectTouch(
      action: action,
      pointerId: ScrcpyControl.pointerIdGenericFinger,
      x: _px(x, frameWidth),
      y: _px(y, frameHeight),
      screenWidth: frameWidth,
      screenHeight: frameHeight,
      pressure: action == ScrcpyControl.actionUp ? 0 : 1,
    );
  }

  List<ScheduledControl> _pointer(PointerInput event) {
    switch (event.button) {
      case PointerButton.secondary:
        return switch (event.action) {
          PointerAction.down => [
            ScheduledControl(
              ScrcpyControl.backOrScreenOn(ScrcpyControl.actionDown),
            ),
          ],
          PointerAction.up => [
            ScheduledControl(
              ScrcpyControl.backOrScreenOn(ScrcpyControl.actionUp),
            ),
          ],
          _ => const [],
        };
      case PointerButton.middle:
        return const [];
      case PointerButton.primary:
        if (!hasFrame) {
          return const [];
        }
        // A desktop window sends the pointer's moves while no button is
        // down (hover); a phone has no hover, and a move without a finger
        // down would be a phantom touch.
        switch (event.action) {
          case PointerAction.down:
            _touching = true;
          case PointerAction.move:
            if (!_touching) {
              return const [];
            }
          case PointerAction.up || PointerAction.cancel:
            if (!_touching) {
              return const [];
            }
            _touching = false;
        }
        final action = switch (event.action) {
          PointerAction.down => ScrcpyControl.actionDown,
          PointerAction.move => ScrcpyControl.actionMove,
          PointerAction.up => ScrcpyControl.actionUp,
          PointerAction.cancel => ScrcpyControl.actionCancel,
        };
        return [ScheduledControl(_touch(action, event.x, event.y))];
    }
  }

  /// A finger (the primary button) is down on the phone's screen.
  bool _touching = false;

  List<ScheduledControl> _scroll(ScrollInput event) {
    if (!hasFrame) {
      return const [];
    }
    if (scrollMode == ScrollMode.drag) {
      return event.precise ? _dragScroll(event) : _wheelSwipe(event);
    }
    final notchesX = event.precise ? event.dx / notchFraction : event.dx;
    final notchesY = event.precise ? event.dy / notchFraction : event.dy;
    if (notchesX == 0 && notchesY == 0) {
      return const [];
    }
    return [
      ScheduledControl(
        ScrcpyControl.injectScroll(
          x: _px(event.x, frameWidth),
          y: _px(event.y, frameHeight),
          screenWidth: frameWidth,
          screenHeight: frameHeight,
          hScroll: -notchesX,
          vScroll: notchesY,
        ),
      ),
    ];
  }

  /// Trackpad: the finger follows the two-finger gesture 1:1 and lifts when
  /// the fingers do, so the app computes its own fling.
  List<ScheduledControl> _dragScroll(ScrollInput event) {
    final out = <ScheduledControl>[];
    if (event.momentumPhase != ScrollPhase.none) {
      return out;
    }
    if (!_dragging &&
        (event.phase == ScrollPhase.began ||
            event.phase == ScrollPhase.changed)) {
      _dragging = true;
      _dragX = event.x;
      _dragY = event.y;
      out.add(
        ScheduledControl(_touch(ScrcpyControl.actionDown, _dragX, _dragY)),
      );
    }
    if (!_dragging) {
      return out;
    }
    if (event.dx != 0 || event.dy != 0) {
      _dragX = (_dragX + event.dx).clamp(0.0, 1.0);
      _dragY = (_dragY + event.dy).clamp(0.0, 1.0);
      out.add(
        ScheduledControl(_touch(ScrcpyControl.actionMove, _dragX, _dragY)),
      );
    }
    if (event.phase == ScrollPhase.ended ||
        event.phase == ScrollPhase.cancelled) {
      _dragging = false;
      out.add(ScheduledControl(_touch(ScrcpyControl.actionUp, _dragX, _dragY)));
    }
    return out;
  }

  /// Mouse wheel in drag mode: each notch becomes one quick swipe.
  List<ScheduledControl> _wheelSwipe(ScrollInput event) {
    if (event.dy == 0 || _dragging) {
      return const [];
    }
    // Wheel down (negative dy) means "next", which is a swipe up.
    final direction = event.dy < 0 ? -1.0 : 1.0;
    final startY = 0.5 - direction * wheelSwipeFraction / 2;
    final endY = 0.5 + direction * wheelSwipeFraction / 2;
    final x = event.x;
    final out = <ScheduledControl>[
      ScheduledControl(_touch(ScrcpyControl.actionDown, x, startY)),
    ];
    for (var step = 1; step <= wheelSwipeSteps; step++) {
      final y = startY + (endY - startY) * step / wheelSwipeSteps;
      out.add(
        ScheduledControl(
          _touch(ScrcpyControl.actionMove, x, y),
          delay: wheelSwipeStep * step,
        ),
      );
    }
    out.add(
      ScheduledControl(
        _touch(ScrcpyControl.actionUp, x, endY),
        delay: wheelSwipeStep * (wheelSwipeSteps + 1),
      ),
    );
    return out;
  }

  List<ScheduledControl> _keycode(
    int keycode, {
    required bool down,
    int meta = 0,
  }) {
    return [
      ScheduledControl(
        ScrcpyControl.injectKeycode(
          action: down ? ScrcpyControl.actionDown : ScrcpyControl.actionUp,
          keycode: keycode,
          metaState: meta,
        ),
      ),
    ];
  }

  List<ScheduledControl> _tap(int keycode, {int meta = 0}) {
    return [
      ..._keycode(keycode, down: true, meta: meta),
      ..._keycode(keycode, down: false, meta: meta),
    ];
  }

  List<ScheduledControl> _key(KeyInput event) {
    if (event.has(InputModifiers.command) ||
        event.has(InputModifiers.control)) {
      final letter = AndroidKeycodes.shortcutLetters[event.macKeyCode];
      if (letter == null) {
        return const [];
      }
      return _keycode(letter, down: event.down, meta: ScrcpyControl.metaCtrl);
    }
    if (event.macKeyCode == AndroidKeycodes.macKeyEscape) {
      return _keycode(AndroidKeycodes.back, down: event.down);
    }
    final special = AndroidKeycodes.fromMacKeyCode[event.macKeyCode];
    if (special != null) {
      final meta = event.has(InputModifiers.shift)
          ? ScrcpyControl.metaShift
          : 0;
      return _keycode(special, down: event.down, meta: meta);
    }
    final characters = event.characters;
    if (!event.down || characters == null || characters.isEmpty) {
      return const [];
    }
    if (characters.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return const [];
    }
    return _text(characters, paste: false);
  }

  List<ScheduledControl> _text(String text, {required bool paste}) {
    if (text.isEmpty) {
      return const [];
    }
    final ascii = text.codeUnits.every((unit) => unit >= 0x20 && unit < 0x7f);
    if (!paste && ascii && text.length <= ScrcpyControl.injectTextMaxLength) {
      return [ScheduledControl(ScrcpyControl.injectText(text))];
    }
    return [
      ScheduledControl(
        ScrcpyControl.setClipboard(
          sequence: _clipboardSequence++,
          text: text,
          paste: true,
        ),
      ),
    ];
  }

  List<ScheduledControl> _navigation(NavigationAction action) {
    return switch (action) {
      NavigationAction.back => _tap(AndroidKeycodes.back),
      NavigationAction.home => _tap(AndroidKeycodes.home),
      NavigationAction.recents => _tap(AndroidKeycodes.appSwitch),
    };
  }
}
