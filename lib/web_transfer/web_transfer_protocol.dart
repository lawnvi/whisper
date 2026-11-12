import 'dart:convert';

// Web transfer, version 1: what a browser and this device say to each other
// over `/w/ws`. One JSON object per WebSocket frame, its type in `t`. See
// docs/internals/web-transfer.md「协议」.

const webTransferVersion = 1;

/// A frame larger than this closes the socket.
const webMaxFrameBytes = 128 * 1024;

/// A text message, in UTF-8.
const webMaxTextBytes = 64 * 1024;

/// One `PUT` of an upload.
const webMaxChunkBytes = 8 * 1024 * 1024;

/// What `welcome` replays.
const webHistoryLimit = 200;

/// Kept free on the disk an upload goes to.
const webFreeSpaceReserve = 1024 * 1024 * 1024;

const webPingInterval = Duration(seconds: 15);

/// The cookie that carries a session to HTTP requests.
const webSessionCookie = 'whisper_web';

/// Frame types, both ways.
abstract final class WebFrame {
  // From the browser.
  static const hello = 'hello';
  static const text = 'text';
  static const offer = 'offer';
  static const cancel = 'cancel';
  static const bye = 'bye';

  // From this device (and `text`).
  static const wait = 'wait';
  static const closed = 'closed';
  static const busy = 'busy';
  static const declined = 'declined';
  static const expired = 'expired';
  static const welcome = 'welcome';
  static const file = 'file';
  static const ack = 'ack';
  static const state = 'state';
  static const ended = 'ended';
}

/// Where an upload is, in `state` frames.
abstract final class WebUploadState {
  static const ready = 'ready';
  static const done = 'done';
  static const refused = 'refused';
  static const failed = 'failed';
  static const cancelled = 'cancelled';
}

String encodeWebFrame(String type, [Map<String, Object?> fields = const {}]) =>
    jsonEncode({'t': type, ...fields});

/// The frame's fields, or null for anything that is not a JSON object with a
/// string `t` within [webMaxFrameBytes].
Map<String, Object?>? decodeWebFrame(Object? data) {
  if (data is! String || data.length > webMaxFrameBytes) {
    return null;
  }
  try {
    final decoded = jsonDecode(data);
    if (decoded is Map<String, Object?> && decoded['t'] is String) {
      return decoded;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// What the browser says about itself. Only what the page guessed from its
/// user agent: never trusted for anything but a name and a picture.
class WebHello {
  const WebHello({
    required this.key,
    required this.os,
    required this.kind,
    required this.browser,
  });

  /// The visitor's secret, 16 random bytes in base64url (22 characters),
  /// kept in the browser's local storage.
  final String key;

  /// `ios`, `android`, `windows`, `mac`, `chromeos`, `linux` or `other`.
  final String os;

  /// `phone`, `tablet` or `laptop`.
  final String kind;

  /// A short lowercase name such as `safari`, or `other`.
  final String browser;

  static final _key = RegExp(r'^[A-Za-z0-9_-]{22}$');
  static const _oses = {
    'ios',
    'android',
    'windows',
    'mac',
    'chromeos',
    'linux',
    'other',
  };
  static const _kinds = {'phone', 'tablet', 'laptop'};
  static final _browser = RegExp(r'^[a-z]{1,16}$');

  /// Null unless it is a version 1 `hello` with a well-formed key. Unknown
  /// systems, shapes and browsers read as `other` and `laptop`.
  static WebHello? parse(Map<String, Object?> frame) {
    final key = frame['key'];
    if (frame['t'] != WebFrame.hello ||
        frame['v'] != webTransferVersion ||
        key is! String ||
        !_key.hasMatch(key)) {
      return null;
    }
    final os = frame['os'];
    final kind = frame['kind'];
    final browser = frame['browser'];
    return WebHello(
      key: key,
      os: os is String && _oses.contains(os) ? os : 'other',
      kind: kind is String && _kinds.contains(kind) ? kind : 'laptop',
      browser: browser is String && _browser.hasMatch(browser)
          ? browser
          : 'other',
    );
  }
}

/// A file the browser wants to send.
class WebOffer {
  const WebOffer({
    required this.id,
    required this.name,
    required this.size,
    required this.type,
  });

  final String id;
  final String name;
  final int size;
  final String type;

  static final _id = RegExp(r'^[0-9a-f-]{36}$');

  /// Ids are the page's UUIDs; a name is cleaned later, when it is saved.
  static WebOffer? parse(Map<String, Object?> frame) {
    final id = frame['id'];
    final name = frame['name'];
    final size = frame['size'];
    final type = frame['type'];
    if (id is! String ||
        !_id.hasMatch(id) ||
        name is! String ||
        name.isEmpty ||
        name.length > 1024 ||
        size is! int ||
        size < 0) {
      return null;
    }
    return WebOffer(
      id: id,
      name: name,
      size: size,
      type: type is String && type.length <= 128 ? type : '',
    );
  }

  static bool isId(Object? value) => value is String && _id.hasMatch(value);
}

/// `Content-Range: bytes <start>-<end>/<total>` of an upload; null when it is
/// not one. An empty file sends `bytes 0-0/0`.
({int start, int end, int total})? parseWebContentRange(String? header) {
  final match = RegExp(
    r'^bytes (\d{1,15})-(\d{1,15})/(\d{1,15})$',
  ).firstMatch(header?.trim() ?? '');
  if (match == null) {
    return null;
  }
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  final total = int.parse(match.group(3)!);
  if (total == 0) {
    return start == 0 && end == 0 ? (start: 0, end: -1, total: 0) : null;
  }
  if (start > end || end >= total) {
    return null;
  }
  return (start: start, end: end, total: total);
}
