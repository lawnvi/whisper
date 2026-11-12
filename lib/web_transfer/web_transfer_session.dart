import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'web_transfer_protocol.dart';
import 'web_transfer_uploads.dart';

/// docs/internals/web-transfer.md「状态机」.
enum WebSessionPhase {
  /// Asked; this device has not answered yet.
  pending,

  /// Allowed, and its page is connected.
  online,

  /// Allowed, but the page went away. It comes back to [online] within the
  /// away time, or the session ends.
  away,

  /// Over. Its cookie no longer opens anything.
  ended,
}

/// One browser's visit: from asking, through any number of reconnections, to
/// the end. Kept in memory only: when the app quits, every visit ends.
class WebSession {
  WebSession({
    required this.uid,
    required this.hello,
    required this.client,
    Random? random,
  }) : code = _digits(random ?? Random.secure()),
       token = _token(random ?? Random.secure());

  /// The visitor's device row (`web-…`).
  final String uid;

  WebHello hello;

  /// The address it asks from, for counting.
  String client;

  /// What both screens show, for the user to compare.
  final String code;

  /// The cookie: 32 random bytes in base64url.
  final String token;

  WebSessionPhase phase = WebSessionPhase.pending;

  WebSocket? socket;

  /// The deadline of the current phase: answering, or coming back.
  Timer? deadline;

  /// Files this visitor is sending, by the page's id.
  final uploads = <String, WebUpload>{};

  /// Downloads under way, cut when the session ends.
  final downloads = <Socket>{};

  bool get live => phase == WebSessionPhase.online;

  /// This device said yes, and the session has not ended.
  bool get allowed =>
      phase == WebSessionPhase.online || phase == WebSessionPhase.away;

  /// Sends a frame when the page is connected; false when it is not.
  bool send(String type, [Map<String, Object?> fields = const {}]) {
    final open = socket;
    if (open == null || open.readyState != WebSocket.open) {
      return false;
    }
    try {
      open.add(encodeWebFrame(type, fields));
      return true;
    } on Object {
      return false;
    }
  }

  /// Closes the page's socket, if any, after [type] when given.
  void hangUp([String? type, Map<String, Object?> fields = const {}]) {
    if (type != null) {
      send(type, fields);
    }
    final open = socket;
    socket = null;
    unawaited(open?.close(WebSocketStatus.normalClosure).catchError((_) {}));
  }

  void cancelDeadline() {
    deadline?.cancel();
    deadline = null;
  }

  static String _digits(Random random) =>
      List.generate(4, (_) => random.nextInt(10)).join();

  static String _token(Random random) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    return List.generate(43, (_) => alphabet[random.nextInt(64)]).join();
  }
}
