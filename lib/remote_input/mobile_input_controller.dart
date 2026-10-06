import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:whisper/remote_input/mobile_motion.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

typedef ManualInputSender =
    int Function(RemoteInputEventType type, Map<String, dynamic> payload);

class MobileInputController extends ChangeNotifier {
  MobileInputController(this.send, {int Function()? monotonicMicros})
    : _monotonicMicros = monotonicMicros;
  final ManualInputSender send;
  final int Function()? _monotonicMicros;
  int get _nowMicros => _monotonicMicros?.call() ?? _clock.elapsedMicroseconds;
  final MobileMotionMapper motion = MobileMotionMapper();
  final Set<String> modifiers = {};
  final Set<int> _buttons = {};
  final Stopwatch _clock = Stopwatch()..start();
  bool _active = false;
  bool air = true;
  bool moving = false;
  bool scrolling = false;
  bool _disposed = false;
  int _suppressUntil = 0;
  Offset _pending = Offset.zero;
  bool _pendingScroll = false;
  Timer? _flushTimer;
  Timer? _repeatDelay;
  Timer? _repeatTimer;

  bool get active => _active;
  set active(bool value) {
    if (_active == value) return;
    reset();
    _active = value;
    notifyListeners();
  }

  void setAir(bool value) {
    reset();
    air = value;
    notifyListeners();
  }

  void holdMotion({required bool down, bool scroll = false}) {
    flush();
    motion.reset();
    if (scroll) {
      scrolling = down;
    } else {
      moving = down;
    }
    notifyListeners();
  }

  void sample(MotionSample sample) {
    final wasCalibrating = motion.calibrating;
    final enabled =
        _active &&
        air &&
        (moving || scrolling || _buttons.contains(0)) &&
        _nowMicros >= _suppressUntil;
    final delta = motion.add(sample, enabled: enabled);
    if (wasCalibrating != motion.calibrating) notifyListeners();
    if (enabled && delta != Offset.zero) {
      move(scrolling ? Offset(0, delta.dy) : delta, scroll: scrolling);
    }
  }

  void move(Offset delta, {bool scroll = false}) {
    if (!_active || !delta.dx.isFinite || !delta.dy.isFinite) return;
    if (_pending != Offset.zero && scroll != _pendingScroll) flush();
    _pendingScroll = scroll;
    _pending += delta;
    _flushTimer ??= Timer(const Duration(microseconds: 16667), flush);
  }

  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final delta = _pending;
    _pending = Offset.zero;
    if (!_active || delta == Offset.zero) return;
    send(
      _pendingScroll
          ? RemoteInputEventType.mouseWheel
          : RemoteInputEventType.mouseMove,
      _pendingScroll
          ? {
              'scrollUnit': 'pixel',
              'scrollDeltaX': delta.dx,
              'scrollDeltaY': delta.dy,
              'sourcePlatform': 'android',
            }
          : {'deltaX': delta.dx, 'deltaY': delta.dy},
    );
  }

  void button(int button, bool down) {
    if (!_active || (down ? !_buttons.add(button) : !_buttons.remove(button))) {
      return;
    }
    flush();
    _suppressUntil = _nowMicros + 80000;
    motion.reset();
    send(RemoteInputEventType.mouseButton, {'button': button, 'down': down});
    notifyListeners();
  }

  void click() {
    button(0, true);
    button(0, false);
  }

  void toggleModifier(String semantic) {
    if (!_active) return;
    if (!modifiers.remove(semantic)) modifiers.add(semantic);
    notifyListeners();
  }

  void key(String semantic) {
    if (!_active) return;
    flush();
    final selected = modifiers.toList();
    for (final modifier in selected) {
      _key(modifier, true);
    }
    _key(semantic, true);
    _key(semantic, false);
    for (final modifier in selected.reversed) {
      _key(modifier, false);
    }
    modifiers.clear();
    notifyListeners();
  }

  void _key(String semantic, bool down) {
    send(RemoteInputEventType.key, {
      ...remoteInputKeyCodes(semantic).toPayloadFields(),
      'sourcePlatform': 'android',
      'down': down,
      if (RemoteInputModifierSemantic.values.any((v) => v.name == semantic))
        'modifierSemantic': semantic,
    });
  }

  void beginRepeat(String semantic, {bool immediate = false}) {
    cancelRepeat();
    if (!_active) return;
    void begin() {
      key(semantic);
      _repeatTimer = Timer.periodic(
        const Duration(milliseconds: 60),
        (_) => key(semantic),
      );
    }

    if (immediate) {
      begin();
    } else {
      _repeatDelay = Timer(const Duration(milliseconds: 400), begin);
    }
  }

  void cancelRepeat() {
    _repeatDelay?.cancel();
    _repeatTimer?.cancel();
    _repeatDelay = null;
    _repeatTimer = null;
  }

  void reset() {
    flush();
    cancelRepeat();
    for (final button in _buttons.toList()) {
      if (_active) {
        send(RemoteInputEventType.mouseButton, {
          'button': button,
          'down': false,
        });
      }
    }
    _buttons.clear();
    modifiers.clear();
    moving = false;
    scrolling = false;
    motion.cancelCalibration();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    reset();
    _clock.stop();
    super.dispose();
  }
}
