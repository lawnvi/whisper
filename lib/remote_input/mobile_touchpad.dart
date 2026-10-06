import 'dart:ui';

/// Keeps a two-finger tap distinct from scrolling until movement is deliberate.
class MobileTouchpad {
  MobileTouchpad({
    required this.move,
    required this.click,
    required this.flush,
    required this.cancel,
  });
  final void Function(Offset delta, {bool scroll}) move;
  final void Function(int button) click;
  final VoidCallback flush, cancel;
  final Map<int, Offset> _positions = {}, _origins = {};
  Duration _started = Duration.zero;
  Offset _pendingScroll = Offset.zero;
  bool _moved = false, _multiple = false, _tapEligible = false;
  int _fingerCount = 0;
  static const tapSlop = 6.0;
  static const tapDuration = Duration(milliseconds: 300);
  static const chordDuration = Duration(milliseconds: 150);

  void down(int pointer, Offset position, Duration time) {
    if (_positions.isEmpty) {
      reset();
      _started = time;
      _tapEligible = true;
    }
    _positions[pointer] = position;
    _origins[pointer] = position;
    _fingerCount++;
    if (_fingerCount > 1) {
      _multiple = true;
      _tapEligible &= time - _started <= chordDuration && _fingerCount == 2;
      flush();
    }
  }

  void update(int pointer, Offset position) {
    final previous = _positions[pointer];
    if (previous == null) return;
    final delta = position - previous;
    _positions[pointer] = position;
    _moved |= (position - _origins[pointer]!).distance > tapSlop;
    if (_multiple) {
      _pendingScroll += delta / _positions.length.toDouble();
      if (_moved) {
        move(_pendingScroll, scroll: true);
        _pendingScroll = Offset.zero;
      }
    } else {
      move(delta, scroll: false);
    }
  }

  void up(int pointer, Duration time) {
    if (_positions.remove(pointer) == null) return;
    flush();
    if (_positions.isNotEmpty) return;
    if (_tapEligible && !_moved && time - _started <= tapDuration) {
      click(_fingerCount == 2 ? 1 : 0);
    }
    reset();
  }

  void pointerCancel() {
    reset();
    cancel();
  }

  void reset() {
    _positions.clear();
    _origins.clear();
    _fingerCount = 0;
    _moved = false;
    _multiple = false;
    _tapEligible = false;
    _pendingScroll = Offset.zero;
  }
}
