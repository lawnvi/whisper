/// The ports Whisper listens on, all counted from the main one (Settings →
/// Server Port, 10002 by default), so a firewall can be told which to let
/// in. A number another program already holds moves on to the next few,
/// then to any free one; the other device learns the number in use from the
/// accept on `/chat`, as before.
abstract final class WhisperPorts {
  /// Keyboard and mouse by UDP: the main port's own number.
  static int inputDatagrams(int main) => main;

  /// The audio isolate's media port, TCP and UDP on the same number (share
  /// links take the one before it, 10003 by default).
  static int audioMedia(int main) => main > 0 ? main + 2 : 0;

  /// How many numbers from the fixed one are tried.
  static const int tries = 8;

  /// [fixed] and the next [tries] - 1 numbers that are ports; none for 0
  /// (any port).
  static Iterable<int> candidates(int fixed) sync* {
    if (fixed <= 0) return;
    for (var port = fixed; port < fixed + tries && port <= 65535; port++) {
      yield port;
    }
  }
}
