import 'dart:math' as math;

/// When a streamed window's picture is ready to show (the rule every
/// receiver shares). While a stream opens, the other device resizes the
/// window for this screen, so the first frames come at the wrong size and
/// then settle; until then the viewer shows a placeholder and a spinner.
///
/// Stable means: a frame was decoded, the last decoded frame has the size
/// of the latest SIZE message (or, from a source that sends none, the size
/// frames last changed to), so at least one frame at the current size, and
/// that size has not changed for 300 ms of streaming (counted from the
/// first frame at the earliest: the size known at open is only the window's
/// size before the source fits it to this screen, which comes a moment
/// after the first frames). One frame is enough: a window that only draws
/// when something changes may send no other. 2.5 s after the first decoded
/// frame the picture counts as stable anyway. Once stable it stays
/// so (the user resizing later brings no spinner back); after a resume the
/// spinner only returns if no new frame arrives within 300 ms.
///
/// Pure and clock-driven, so it can be tested without timers: feed it
/// [sizeMessage], [frame], [resumed] and call [check] at [nextCheck].
class PictureSettle {
  PictureSettle({required Duration Function() now}) : _now = now {
    _openedAt = now();
  }

  final Duration Function() _now;

  static const quiet = Duration(milliseconds: 300);
  static const cap = Duration(milliseconds: 2500);
  static const resumeGrace = Duration(milliseconds: 300);
  static const slowAfter = Duration(seconds: 8);

  /// Encoders may round a size to even pixels.
  static const sizeSlack = 2;

  late final Duration _openedAt;
  ({int width, int height})? _expected;
  Duration? _expectedAt;

  /// The expected size came from decoded frames (the source sends no SIZE
  /// messages), not from the source.
  bool _expectedFromFrames = false;
  ({int width, int height})? _decoded;
  Duration? _firstFrameAt;
  Duration? _lastFrameAt;
  bool _stable = false;

  /// Resumed and waiting for a new frame since then.
  Duration? _waitingSince;

  /// The picture has settled: show it.
  bool get stable => _stable;

  /// Something to wait for: before the picture settles, or after a resume
  /// that brought no frame within [resumeGrace].
  bool get loading => !_stable || _resumeStalled;

  /// Waiting longer than it should: nothing decoded for [slowAfter] while
  /// [loading] (the "still connecting" hint shows).
  bool get slow {
    if (!loading) {
      return false;
    }
    var since = _lastFrameAt ?? _openedAt;
    final waiting = _waitingSince;
    if (waiting != null && waiting > since) {
      since = waiting;
    }
    return _now() - since >= slowAfter;
  }

  bool get _resumeStalled {
    final since = _waitingSince;
    return since != null && _now() - since >= resumeGrace;
  }

  /// Frames are wanted (the decoder should report each one).
  bool get watching => !_stable || _waitingSince != null;

  /// The source said the video is now [width]×[height] (its SIZE message).
  void sizeMessage(int width, int height) {
    if (width <= 0 || height <= 0) {
      return;
    }
    final size = (width: width, height: height);
    if (size == _expected && !_expectedFromFrames) {
      return;
    }
    if (size != _expected) {
      _expectedAt = _now();
    }
    _expected = size;
    _expectedFromFrames = false;
    check();
  }

  /// A frame of [width]×[height] pixels was decoded.
  void frame(int width, int height) {
    final now = _now();
    final size = (width: width, height: height);
    _decoded = size;
    _firstFrameAt ??= now;
    _lastFrameAt = now;
    _waitingSince = null;
    if (_expected == null || (_expectedFromFrames && size != _expected)) {
      // No SIZE message (yet): a change of the decoded size stands in.
      _expected = size;
      _expectedFromFrames = true;
      _expectedAt = now;
    }
    check();
  }

  /// The picture settled before this (a window opened again from its
  /// card): show it now, as after a resume.
  void alreadySettled() {
    _stable = true;
    _settledByCap = false;
  }

  /// Settled only because [cap] ran out (for logs).
  bool get settledByCap => _settledByCap;
  bool _settledByCap = false;

  /// The stream was paused (or the app was away) and plays again.
  void resumed() {
    if (_stable) {
      _waitingSince = _now();
    }
  }

  /// Re-evaluates the rule (call on events and at [nextCheck]).
  void check() {
    if (_stable) {
      return;
    }
    final now = _now();
    final first = _firstFrameAt;
    if (first != null && now - first >= cap) {
      _stable = true;
      _settledByCap = true;
      return;
    }
    final expected = _expected;
    final decoded = _decoded;
    final at = _expectedAt;
    if (expected == null || decoded == null || at == null) {
      return;
    }
    if ((expected.width - decoded.width).abs() > sizeSlack ||
        (expected.height - decoded.height).abs() > sizeSlack) {
      return;
    }
    if (now - _quietSince(at, first) < quiet) {
      return;
    }
    _stable = true;
  }

  /// The size has held since then: its last change, but not before the
  /// first frame.
  static Duration _quietSince(Duration sizeAt, Duration? firstFrameAt) =>
      firstFrameAt != null && firstFrameAt > sizeAt ? firstFrameAt : sizeAt;

  /// When the outcome can next change without a new event (a 300 ms quiet
  /// period ending, the 2.5 s cap, the resume grace, the slow hint), or
  /// null when nothing is pending.
  Duration? nextCheck() {
    final now = _now();
    final candidates = <Duration>[];
    if (!_stable) {
      if (_expectedAt != null) {
        candidates.add(_quietSince(_expectedAt!, _firstFrameAt) + quiet);
      }
      if (_firstFrameAt != null) {
        candidates.add(_firstFrameAt! + cap);
      }
      candidates.add((_lastFrameAt ?? _openedAt) + slowAfter);
    }
    final waiting = _waitingSince;
    if (waiting != null) {
      candidates.add(waiting + resumeGrace);
      candidates.add(waiting + slowAfter);
    }
    final upcoming = candidates.where((at) => at > now);
    if (upcoming.isEmpty) {
      return null;
    }
    return upcoming.reduce((a, b) => a < b ? a : b) - now + _tick;
  }

  /// A hair past the deadline, so the check lands after it.
  static const _tick = Duration(milliseconds: 1);

  /// For logs: the state in a few words.
  String describe() {
    final now = _now();
    String ms(Duration? at) =>
        at == null ? '-' : '${math.max(0, (now - at).inMilliseconds)}ms';
    return 'stable=$_stable expected=${_expected?.width}x'
        '${_expected?.height}${_expectedFromFrames ? '(frames)' : ''} '
        'decoded=${_decoded?.width}x${_decoded?.height} '
        'sinceSize=${ms(_expectedAt)} '
        'sinceFirst=${ms(_firstFrameAt)}';
  }
}
