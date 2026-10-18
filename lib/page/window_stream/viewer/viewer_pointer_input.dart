import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../window_stream/core/window_input_event.dart';

/// Turns everything that points at the streamed picture into the other
/// device's pointer, the way the Android viewer does, plus what an iPad
/// adds (sill's InputOverlay is the model):
///
/// - a finger: tap clicks; sliding scrolls (one or two fingers), with the
///   coast after a flick made here since injected scrolls get none over
///   there; press and hold then move drags; press and hold right-clicks;
///   a two-finger tap right-clicks;
/// - a mouse, the trackpad's pointer or the Pencil: the pointer itself.
///   Hovering moves it, pressing clicks (the secondary button
///   right-clicks), moving while pressed drags;
/// - a wheel scrolls; the trackpad's two-finger scroll scrolls in phases,
///   then coasts like a finger's.
///
/// Positions leave as fractions of the picture ([picture], in the
/// listener's coordinates). Scroll deltas are fractions of the picture
/// too, natural direction (content follows the finger).
class ViewerPointerInput {
  ViewerPointerInput({
    required this.send,
    required TickerProvider vsync,
    this.onLongPress,
  }) {
    _ticker = vsync.createTicker(_coast);
  }

  final void Function(WindowInputEvent event) send;

  /// Press and hold was recognized (for a haptic).
  final VoidCallback? onLongPress;

  /// Where the video is drawn, in the listener's local coordinates.
  Rect picture = Rect.zero;

  /// Input only goes out while the picture is live.
  bool enabled = true;

  /// Movement beyond this many points makes a touch a scroll or a drag.
  static const double slop = 10;
  static const Duration holdDelay = Duration(milliseconds: 450);
  static const Duration twoFingerTapLimit = Duration(milliseconds: 400);

  /// Hover moves go out at most this often (120 Hz).
  static const Duration hoverInterval = Duration(microseconds: 8333);

  /// A flick slower than this (points per second) does not coast.
  static const double minimumFlingSpeed = 150;

  /// The coast ends below this speed.
  static const double stopSpeed = 18;

  /// UIScrollView's normal deceleration: speed kept per millisecond.
  static const double decelerationPerMs = 0.998;

  late final Ticker _ticker;

  // ---------------------------------------------------------------- touch

  final Map<int, Offset> _touches = {};

  /// The finger that went down first: the one a hold-and-drag follows.
  int? _firstFinger;
  _TouchMode _mode = _TouchMode.none;
  bool _twoFinger = false;
  Offset _downAt = Offset.zero;
  Duration _downTime = Duration.zero;
  Offset _lastCentroid = Offset.zero;
  Offset _scrollAnchor = Offset.zero;
  Timer? _holdTimer;
  VelocityTracker? _velocity;

  // ------------------------------------------------------- mouse and pencil

  final Map<int, PointerButton> _pressed = {};
  Duration? _lastHover;
  Offset? _pendingHover;
  Timer? _hoverTimer;

  // ---------------------------------------------------------- trackpad

  Offset _panAnchor = Offset.zero;
  bool _panOpen = false;
  VelocityTracker? _panVelocity;

  // ------------------------------------------------------------ coast

  Offset _coastSpeed = Offset.zero;
  Offset _coastAnchor = Offset.zero;
  Duration? _coastLast;

  /// A scroll gesture is open over there (a finger's, the trackpad's, or a
  /// coast after either).
  bool get scrolling => _mode == _TouchMode.scroll || _panOpen || coasting;

  bool get coasting => _ticker.isActive;

  void dispose() {
    _holdTimer?.cancel();
    _hoverTimer?.cancel();
    stopCoast();
    _ticker.dispose();
  }

  /// Ends whatever is in progress (the viewer is leaving or pausing):
  /// buttons come up, a scroll ends.
  void reset() {
    _holdTimer?.cancel();
    stopCoast();
    if (_mode == _TouchMode.scroll) {
      _scroll(ScrollPhase.ended, Offset.zero, _scrollAnchor);
    } else if (_mode == _TouchMode.drag) {
      _pointer(PointerAction.up, _lastCentroid, clamp: true);
    }
    _mode = _TouchMode.none;
    _touches.clear();
    if (_panOpen) {
      _panOpen = false;
      _scroll(ScrollPhase.ended, Offset.zero, _panAnchor);
    }
    for (final entry in _pressed.entries.toList()) {
      _pointer(
        PointerAction.up,
        _lastPointer,
        clamp: true,
        button: entry.value,
      );
    }
    _pressed.clear();
  }

  Offset _lastPointer = Offset.zero;

  // ------------------------------------------------------------ mapping

  /// [local] as a fraction of the picture; null outside it unless
  /// [clamp] (moves, drags and scrolls keep working past the edge; a tap
  /// on the black bars is no click).
  Offset? fraction(Offset local, {required bool clamp}) {
    final rect = picture;
    if (rect.width <= 0 || rect.height <= 0) {
      return null;
    }
    final x = (local.dx - rect.left) / rect.width;
    final y = (local.dy - rect.top) / rect.height;
    if (x < 0 || x > 1 || y < 0 || y > 1) {
      if (!clamp) {
        return null;
      }
      return Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
    }
    return Offset(x, y);
  }

  bool _pointer(
    PointerAction action,
    Offset local, {
    required bool clamp,
    PointerButton button = PointerButton.primary,
  }) {
    final point = fraction(local, clamp: clamp);
    if (point == null || !enabled) {
      return false;
    }
    send(
      PointerInput(action: action, x: point.dx, y: point.dy, button: button),
    );
    return true;
  }

  void _click(Offset local, PointerButton button) {
    // The pointer goes there first: hover state (menus, tooltips) follows
    // it, and the click lands where it is.
    if (!_pointer(PointerAction.move, local, clamp: false)) {
      return;
    }
    _pointer(PointerAction.down, local, clamp: false, button: button);
    _pointer(PointerAction.up, local, clamp: false, button: button);
  }

  void _scroll(ScrollPhase phase, Offset delta, Offset anchor) {
    final rect = picture;
    final point = fraction(anchor, clamp: true);
    if (point == null || !enabled) {
      return;
    }
    send(
      ScrollInput(
        x: point.dx,
        y: point.dy,
        dx: rect.width > 0 ? delta.dx / rect.width : 0,
        dy: rect.height > 0 ? delta.dy / rect.height : 0,
        phase: phase,
        precise: true,
      ),
    );
  }

  static bool _isTouch(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.touch || kind == PointerDeviceKind.unknown;

  static PointerButton _buttonOf(int buttons) {
    if (buttons & kSecondaryMouseButton != 0) {
      return PointerButton.secondary;
    }
    if (buttons & kMiddleMouseButton != 0) {
      return PointerButton.middle;
    }
    return PointerButton.primary;
  }

  Offset get _centroid {
    if (_touches.isEmpty) {
      return _lastCentroid;
    }
    var sum = Offset.zero;
    for (final position in _touches.values) {
      sum += position;
    }
    return sum / _touches.length.toDouble();
  }

  // ------------------------------------------------------------ events

  void onPointerDown(PointerDownEvent event) {
    // Touching content that is still coasting stops it, as on iOS.
    stopCoast();
    if (!_isTouch(event.kind)) {
      final button = _buttonOf(event.buttons);
      _lastPointer = event.localPosition;
      if (!_pointer(PointerAction.move, event.localPosition, clamp: false)) {
        return;
      }
      _pressed[event.pointer] = button;
      _pointer(
        PointerAction.down,
        event.localPosition,
        clamp: false,
        button: button,
      );
      return;
    }
    _touches[event.pointer] = event.localPosition;
    if (_touches.length == 1) {
      _firstFinger = event.pointer;
      _mode = _TouchMode.pending;
      _twoFinger = false;
      _downAt = event.localPosition;
      _downTime = event.timeStamp;
      _lastCentroid = event.localPosition;
      _velocity = VelocityTracker.withKind(PointerDeviceKind.touch)
        ..addPosition(event.timeStamp, event.localPosition);
      _holdTimer?.cancel();
      _holdTimer = Timer(holdDelay, _onHold);
      return;
    }
    // Another finger joins: a two-finger tap or scroll, never a hold.
    if (_mode == _TouchMode.pending || _mode == _TouchMode.held) {
      _twoFinger = true;
      _mode = _TouchMode.pending;
      _holdTimer?.cancel();
    }
    // The centroid jumps when a finger lands; measure from where it is now.
    _lastCentroid = _centroid;
    _velocity = VelocityTracker.withKind(PointerDeviceKind.touch)
      ..addPosition(event.timeStamp, _lastCentroid);
  }

  void _onHold() {
    if (_mode == _TouchMode.pending && !_twoFinger && _touches.length == 1) {
      _mode = _TouchMode.held;
      onLongPress?.call();
    }
  }

  void onPointerMove(PointerMoveEvent event) {
    if (!_isTouch(event.kind)) {
      _lastPointer = event.localPosition;
      if (_pressed.containsKey(event.pointer)) {
        // Moving with the button down drags over there.
        _pointer(PointerAction.move, event.localPosition, clamp: true);
      }
      return;
    }
    if (!_touches.containsKey(event.pointer)) {
      return;
    }
    _touches[event.pointer] = event.localPosition;
    final centroid = _centroid;
    _velocity?.addPosition(event.timeStamp, centroid);
    switch (_mode) {
      case _TouchMode.pending:
        final travelled = _twoFinger
            ? (centroid - _lastCentroid).distance
            : (event.localPosition - _downAt).distance;
        if (travelled > slop) {
          _holdTimer?.cancel();
          _mode = _TouchMode.scroll;
          _scrollAnchor = _twoFinger ? centroid : _downAt;
          _scroll(ScrollPhase.began, Offset.zero, _scrollAnchor);
          final from = _twoFinger ? _lastCentroid : _downAt;
          _scroll(ScrollPhase.changed, centroid - from, _scrollAnchor);
          _lastCentroid = centroid;
        }
      case _TouchMode.held:
        if ((event.localPosition - _downAt).distance > slop) {
          _mode = _TouchMode.drag;
          _pointer(PointerAction.move, _downAt, clamp: true);
          _pointer(PointerAction.down, _downAt, clamp: true);
          _pointer(PointerAction.move, event.localPosition, clamp: true);
          _lastCentroid = event.localPosition;
        }
      case _TouchMode.scroll:
        _scroll(ScrollPhase.changed, centroid - _lastCentroid, _scrollAnchor);
        _lastCentroid = centroid;
      case _TouchMode.drag:
        if (event.pointer == _firstFinger) {
          _pointer(PointerAction.move, event.localPosition, clamp: true);
          _lastCentroid = event.localPosition;
        }
      case _TouchMode.none:
        break;
    }
  }

  void onPointerUp(PointerUpEvent event) {
    if (!_isTouch(event.kind)) {
      _lastPointer = event.localPosition;
      final button = _pressed.remove(event.pointer);
      if (button != null) {
        _pointer(
          PointerAction.up,
          event.localPosition,
          clamp: true,
          button: button,
        );
      }
      return;
    }
    if (_touches.remove(event.pointer) == null) {
      return;
    }
    if (_touches.isNotEmpty) {
      if (_mode == _TouchMode.drag) {
        if (event.pointer == _firstFinger) {
          // The dragging finger lifted: the drop happens here.
          _pointer(PointerAction.up, event.localPosition, clamp: true);
          _mode = _TouchMode.none;
        }
        return;
      }
      // A finger of two lifted: carry on from where the rest are.
      _lastCentroid = _centroid;
      return;
    }
    _holdTimer?.cancel();
    final quick = event.timeStamp - _downTime < twoFingerTapLimit;
    switch (_mode) {
      case _TouchMode.pending when _twoFinger:
        if (quick) {
          _click(_downAt, PointerButton.secondary);
        }
      case _TouchMode.pending:
        _click(_downAt, PointerButton.primary);
      case _TouchMode.held:
        _click(_downAt, PointerButton.secondary);
      case _TouchMode.drag:
        _pointer(PointerAction.up, event.localPosition, clamp: true);
      case _TouchMode.scroll:
        final velocity =
            _velocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
        _mode = _TouchMode.none;
        _startCoast(velocity, _scrollAnchor);
        _velocity = null;
        return;
      case _TouchMode.none:
        break;
    }
    _mode = _TouchMode.none;
    _velocity = null;
  }

  void onPointerCancel(PointerCancelEvent event) {
    if (!_isTouch(event.kind)) {
      final button = _pressed.remove(event.pointer);
      if (button != null) {
        // Never leave a button stuck down.
        _pointer(PointerAction.up, _lastPointer, clamp: true, button: button);
      }
      return;
    }
    if (_touches.remove(event.pointer) == null || _touches.isNotEmpty) {
      return;
    }
    _holdTimer?.cancel();
    switch (_mode) {
      case _TouchMode.scroll:
        _scroll(ScrollPhase.ended, Offset.zero, _scrollAnchor);
      case _TouchMode.drag:
        _pointer(PointerAction.up, _lastCentroid, clamp: true);
      default:
        break;
    }
    _mode = _TouchMode.none;
  }

  /// A mouse, the trackpad's pointer or a hovering Pencil moved without a
  /// button: the pointer over there follows, at most [hoverInterval] apart
  /// (the last position always goes out).
  void onPointerHover(PointerHoverEvent event) {
    if (_isTouch(event.kind)) {
      return;
    }
    _lastPointer = event.localPosition;
    final last = _lastHover;
    final since = last == null ? null : event.timeStamp - last;
    if (since == null || since >= hoverInterval || since.isNegative) {
      _hoverTimer?.cancel();
      _hoverTimer = null;
      _pendingHover = null;
      _lastHover = event.timeStamp;
      _pointer(PointerAction.move, event.localPosition, clamp: true);
      return;
    }
    _pendingHover = event.localPosition;
    final wait = hoverInterval - since;
    final sendAt = event.timeStamp + wait;
    _hoverTimer ??= Timer(wait, () {
      _hoverTimer = null;
      final position = _pendingHover;
      _pendingHover = null;
      if (position != null && _pressed.isEmpty) {
        _lastHover = sendAt;
        _pointer(PointerAction.move, position, clamp: true);
      }
    });
  }

  /// A mouse wheel: plain deltas at the pointer, no gesture around them
  /// and no coast.
  void onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    stopCoast();
    _lastPointer = event.localPosition;
    final rect = picture;
    final point = fraction(event.localPosition, clamp: true);
    if (point == null || !enabled || rect.isEmpty) {
      return;
    }
    // Flutter's scroll delta moves the view; content moves the other way.
    send(
      ScrollInput(
        x: point.dx,
        y: point.dy,
        dx: -event.scrollDelta.dx / rect.width,
        dy: -event.scrollDelta.dy / rect.height,
        precise: true,
      ),
    );
  }

  /// The trackpad's two-finger scroll: a gesture with phases, at the
  /// pointer, then the same coast as a finger's (iPadOS hands none).
  void onPointerPanZoomStart(PointerPanZoomStartEvent event) {
    stopCoast();
    _panAnchor = event.localPosition;
    _panOpen = true;
    _panVelocity = VelocityTracker.withKind(PointerDeviceKind.touch)
      ..addPosition(event.timeStamp, Offset.zero);
    _scroll(ScrollPhase.began, Offset.zero, _panAnchor);
  }

  void onPointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (!_panOpen) {
      return;
    }
    _panVelocity?.addPosition(event.timeStamp, event.localPan);
    final delta = event.localPanDelta;
    if (delta != Offset.zero) {
      _scroll(ScrollPhase.changed, delta, _panAnchor);
    }
  }

  void onPointerPanZoomEnd(PointerPanZoomEndEvent event) {
    if (!_panOpen) {
      return;
    }
    _panOpen = false;
    final velocity = _panVelocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
    _panVelocity = null;
    _startCoast(velocity, _panAnchor);
  }

  // ------------------------------------------------------------ coast

  void _startCoast(Offset velocity, Offset anchor) {
    if (velocity.distance < minimumFlingSpeed) {
      _scroll(ScrollPhase.ended, Offset.zero, anchor);
      return;
    }
    _coastSpeed = velocity;
    _coastAnchor = anchor;
    _coastLast = null;
    _ticker.start();
  }

  void _coast(Duration elapsed) {
    final last = _coastLast;
    _coastLast = elapsed;
    if (last == null) {
      return;
    }
    final ms = (elapsed - last).inMicroseconds / 1000;
    if (ms <= 0) {
      return;
    }
    _coastSpeed *= math.pow(decelerationPerMs, ms).toDouble();
    _scroll(ScrollPhase.changed, _coastSpeed * (ms / 1000), _coastAnchor);
    if (_coastSpeed.distance < stopSpeed) {
      _ticker.stop();
      _scroll(ScrollPhase.ended, Offset.zero, _coastAnchor);
    }
  }

  /// Stops a coast in progress; its gesture ends over there.
  void stopCoast() {
    if (!_ticker.isActive) {
      return;
    }
    _ticker.stop();
    _scroll(ScrollPhase.ended, Offset.zero, _coastAnchor);
  }
}

enum _TouchMode { none, pending, held, scroll, drag }
