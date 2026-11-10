/// Which packets of a stream play, as they come: each sequence once (a
/// packet can come twice, in two datagrams or by both ways while the source
/// changes over between UDP and the WebSocket), and a few that never came
/// before one that did are filled in with the decoder's guess. A longer gap
/// stays silent: the sound really stopped there.
class AudioPacketGaps {
  static const int maxFilled = 3;
  static const int _restartGap = 256;

  final Set<int> _seen = <int>{};
  int? _next;

  /// What came of the packets so far, for diagnostics.
  int played = 0, filled = 0, repeats = 0, silent = 0;

  ({bool play, List<int> fill}) take(int sequence) {
    final next = _next;
    if (next != null && sequence + _restartGap < next) {
      // Far behind: the source started counting again.
      _seen.clear();
      _next = null;
    }
    if (!_seen.add(sequence)) {
      repeats += 1;
      return (play: false, fill: const []);
    }
    played += 1;
    if (_seen.length > 2 * _restartGap) {
      _seen.removeWhere((seen) => seen + _restartGap < sequence);
    }
    final fill = <int>[];
    final expected = _next;
    if (expected != null &&
        sequence > expected &&
        sequence - expected <= maxFilled) {
      for (var missing = expected; missing < sequence; missing++) {
        if (_seen.add(missing)) fill.add(missing);
      }
      filled += fill.length;
    } else if (expected != null && sequence > expected) {
      silent += sequence - expected;
    }
    if (expected == null || sequence >= expected) _next = sequence + 1;
    return (play: true, fill: fill);
  }
}
