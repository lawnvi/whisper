import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:whisper/remote_input/mobile_motion.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

typedef ManualInputSender =
    int Function(RemoteInputEventType type, Map<String, dynamic> payload);

class MobileInputController extends ChangeNotifier {
  static const keyRepeatDelay = Duration(milliseconds: 400);
  static const _keyRepeatInterval = Duration(milliseconds: 60);
  static const _motionSuppression = Duration(milliseconds: 80);
  static const _movementFrameInterval = Duration(microseconds: 16667);

  MobileInputController(this.send, {int Function()? monotonicMicros})
    : _monotonicMicros = monotonicMicros;
  final ManualInputSender send;
  final int Function()? _monotonicMicros;
  int get _nowMicros => _monotonicMicros?.call() ?? _clock.elapsedMicroseconds;
  final MobileMotionMapper motion = MobileMotionMapper();
  final Set<String> modifiers = {};
  final Set<int> _buttons = {};
  final Stopwatch _clock = Stopwatch()..start();
  double pointerSpeed = 1.0;
  double scrollSpeed = 1.0;
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

  void setPointerSpeed(double value) {
    flush();
    pointerSpeed = value.isFinite ? value.clamp(0.5, 3.0) : 1.0;
    notifyListeners();
  }

  void setScrollSpeed(double value) {
    flush();
    scrollSpeed = value.isFinite ? value.clamp(0.5, 3.0) : 1.0;
    notifyListeners();
  }

  void setSensitivity(double value) {
    motion.sensitivity = value;
    notifyListeners();
  }

  void calibrate() {
    motion.calibrate();
    notifyListeners();
  }

  void cancelCalibration() {
    motion.cancelCalibration();
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

  void toggleMotion() {
    if (!_active || !air) return;
    if (moving) {
      reset();
    } else {
      holdMotion(down: true);
      _suppressUntil = _nowMicros + _motionSuppression.inMicroseconds;
    }
  }

  void sample(MotionSample sample) {
    final wasCalibrating = motion.calibrating;
    final enabled =
        _active &&
        air &&
        (moving || scrolling || _buttons.contains(0)) &&
        _nowMicros >= _suppressUntil;
    final delta = motion.add(
      sample,
      enabled: enabled,
      learnBias: _active && air && !moving && !scrolling && _buttons.isEmpty,
    );
    if (wasCalibrating != motion.calibrating) notifyListeners();
    if (enabled && delta != Offset.zero) {
      move(
        scrolling ? Offset(0, delta.dy) : delta,
        scroll: scrolling,
        fromMotion: true,
      );
    }
  }

  void move(Offset delta, {bool scroll = false, bool fromMotion = false}) {
    if (!_active || !delta.dx.isFinite || !delta.dy.isFinite) return;
    if (_pending != Offset.zero && scroll != _pendingScroll) flush();
    _pendingScroll = scroll;
    _pending +=
        delta *
        (scroll
            ? scrollSpeed
            : fromMotion
            ? 1.0
            : pointerSpeed);
    _flushTimer ??= Timer(_movementFrameInterval, flush);
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
    _suppressUntil = _nowMicros + _motionSuppression.inMicroseconds;
    motion.reset();
    send(RemoteInputEventType.mouseButton, {'button': button, 'down': down});
    notifyListeners();
  }

  void click([int buttonNumber = 0]) {
    // A touchpad tap must not release a button held by another finger.
    if (_buttons.isNotEmpty) return;
    button(buttonNumber, true);
    button(buttonNumber, false);
  }

  void toggleModifier(String semantic) {
    if (!_active) return;
    if (!modifiers.remove(semantic)) modifiers.add(semantic);
    notifyListeners();
  }

  void key(String semantic, {bool? shift}) {
    if (!_active) return;
    flush();
    // Symbol keys supply their own Shift state without leaving it latched.
    final selected = {...modifiers};
    if (shift == true) selected.add('shift');
    if (shift == false) selected.remove('shift');
    for (final modifier in selected) {
      _key(modifier, true);
    }
    _key(semantic, true);
    _key(semantic, false);
    for (final modifier in selected.toList().reversed) {
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
      _repeatTimer = Timer.periodic(_keyRepeatInterval, (_) => key(semantic));
    }

    if (immediate) {
      begin();
    } else {
      _repeatDelay = Timer(keyRepeatDelay, begin);
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
