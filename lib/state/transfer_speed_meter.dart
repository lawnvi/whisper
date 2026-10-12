import 'dart:collection';

/// The speed shown while a transfer runs: an average over the last few
/// seconds rather than the difference between two updates.
///
/// Progress does not arrive evenly. A folder alternates between large files
/// and runs of tiny ones, and a reading taken between neighbouring updates
/// swung between 0.1 and 80 MB/s within a second when it was measured.
final class TransferSpeedMeter {
  TransferSpeedMeter({
    this.window = const Duration(seconds: 3),
    this.minimumSpan = const Duration(milliseconds: 400),
  });

  /// How far back the average reaches.
  final Duration window;

  /// Below this much history there is no reading: two updates a few
  /// milliseconds apart say nothing about the speed.
  final Duration minimumSpan;

  final Queue<({int atMs, int bytes})> _samples =
      Queue<({int atMs, int bytes})>();

  /// Records that [bytes] of the transfer were done at [nowMs].
  void add(int nowMs, int bytes) {
    if (_samples.isNotEmpty &&
        (bytes < _samples.last.bytes || nowMs < _samples.last.atMs)) {
      // The transfer started over or the clock was set back.
      _samples.clear();
    }
    _samples.add((atMs: nowMs, bytes: bytes));
    // The oldest sample kept is the last one from before the window, so the
    // average always spans the whole window once there is that much history.
    while (_samples.length > 2 &&
        nowMs - _samples.elementAt(1).atMs >= window.inMilliseconds) {
      _samples.removeFirst();
    }
  }

  /// Bytes per second over the window, or null while there is too little to
  /// go by.
  int? get bytesPerSecond {
    if (_samples.length < 2) {
      return null;
    }
    final span = _samples.last.atMs - _samples.first.atMs;
    if (span < minimumSpan.inMilliseconds) {
      return null;
    }
    return (_samples.last.bytes - _samples.first.bytes) * 1000 ~/ span;
  }

  void reset() => _samples.clear();
}
