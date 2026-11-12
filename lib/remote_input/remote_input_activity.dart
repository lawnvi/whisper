/// When a key, button, wheel or pointer move last went to another device or
/// came from one. While they do, a file transfer does not try how much more
/// the link carries: that fills it for seconds, and the pointer lags.
abstract final class RemoteInputActivity {
  static DateTime? _last;

  static void note() => _last = DateTime.now();

  /// Whether one went or came within [span].
  static bool within(Duration span) {
    final last = _last;
    return last != null && DateTime.now().difference(last) < span;
  }
}
