import 'dart:convert';
import 'dart:typed_data';

/// Control messages for streaming a desktop's windows to another Whisper
/// peer, carried as `MessageEnum.WindowStreamControl` on the chat channel.
///
/// Two kinds of sessions, each with its own session id:
/// - a browse session (`browse` → `catalog`, `icon`, `thumbnail`) that lists
///   the host's apps and windows;
/// - one stream session per opened window (`open` → `accept`/`reject`, then
///   `pause`, `resume`, `keyframe`, `stop`). The accept carries a one-time
///   token for the `/window` media route;
/// - a one-message `offer` session: the host sends one of its windows to the
///   viewer ("送出去"). It is the only session the host starts; the viewer
///   then opens the window with an ordinary `open`.
///
/// Wire naming: the generic control envelope calls the peer that starts a
/// session its "source" and the other one its "sink", and the media-token
/// checks rely on that. Here the viewer starts every session and dials the
/// media route, so the wire `sourcePeerId` is the **viewer** and
/// `sinkPeerId` the **host**, even though video flows host → viewer.
enum WindowStreamControlAction {
  browse,
  catalog,
  icon,
  thumbnail,
  open,
  accept,
  reject,
  pause,
  resume,
  keyframe,
  stop,
  error,
  offer,

  /// Viewer → host: its screen size (points) and text scale changed.
  viewport,

  /// Viewer → host, on the browse session: close a window on the host as
  /// its own close button would.
  closeWindow,

  /// Host → viewer, on the browse session: how a `closeWindow` went —
  /// `closed`, or `open` while the window stays (an app asking whether to
  /// save). An `open` window that closes later is followed by `closed`.
  closeResult,

  /// Viewer → host, after an `accept` that said `hostDials` (see
  /// [WindowStreamMediaDial]): a one-time token for the viewer's own
  /// `/window`, which the host then dials.
  dial,
}

/// Who dials the `/window` media connection.
///
/// Normally the viewer dials the host. A phone often cannot be reached from
/// outside (a VPN, AP isolation, a hotspot), but it reached the viewer when
/// it opened the Whisper session, so a phone host that is that session's
/// client dials the viewer's Whisper port instead:
/// - the viewer says it can take that dial with `"dialBack": true` in
///   `open` (viewers before this key never get dialled);
/// - the host answers `"hostDials": true` in `accept` only then, and only
///   when it is a phone and the client of the session;
/// - the viewer then sends `dial` with a token it issued, and the host
///   dials `/window` with it, proving the token with its own media send key.
/// Video and input keep their keys: the host encrypts video with its send
/// key, the viewer its input with its own.
abstract final class WindowStreamMediaDial {
  static const String dialBackKey = 'dialBack';
  static const String hostDialsKey = 'hostDials';
}

class WindowStreamControlMessage {
  const WindowStreamControlMessage({
    required this.action,
    required this.sessionId,
    required this.viewerPeerId,
    required this.hostPeerId,
    this.payload = const <String, Object?>{},
    this.transportToken = '',
    this.transportPort,
  });

  factory WindowStreamControlMessage.fromJson(Map<String, dynamic> json) {
    final action = WindowStreamControlAction.values.asNameMap()[json['action']];
    if (action == null) {
      throw const FormatException('unknown window stream action');
    }
    final payload = json['payload'];
    if (payload != null && payload is! Map) {
      throw const FormatException('window stream payload must be an object');
    }
    final token = json['transportToken'];
    if (_carriesToken(action)) {
      if (token is! String || token.isEmpty || token.length > 128) {
        throw const FormatException('accept requires a transport token');
      }
    } else if (token != null) {
      throw const FormatException('only accept carries a transport token');
    }
    final port = json['transportPort'];
    if (port != null && (port is! int || port <= 0 || port > 65535)) {
      throw const FormatException('invalid transport port');
    }
    return WindowStreamControlMessage(
      action: action,
      sessionId: json['sessionId'] as String,
      viewerPeerId: json['sourcePeerId'] as String,
      hostPeerId: json['sinkPeerId'] as String,
      payload: (payload as Map?)?.cast<String, Object?>() ?? const {},
      transportToken: token as String? ?? '',
      transportPort: port as int?,
    );
  }

  /// `accept` (host's `/window`) and `dial` (viewer's) carry a token.
  static bool _carriesToken(WindowStreamControlAction action) =>
      action == WindowStreamControlAction.accept ||
      action == WindowStreamControlAction.dial;

  final WindowStreamControlAction action;
  final String sessionId;
  final String viewerPeerId;
  final String hostPeerId;
  final Map<String, Object?> payload;
  final String transportToken;
  final int? transportPort;

  /// Starts a new session (validated as the session's first message).
  bool get isInitial =>
      action == WindowStreamControlAction.browse ||
      action == WindowStreamControlAction.open ||
      action == WindowStreamControlAction.offer;

  /// The host starts this session, against the usual viewer-first
  /// direction of the wire checks.
  bool get isHostInitiated => action == WindowStreamControlAction.offer;

  bool get isTerminal =>
      action == WindowStreamControlAction.reject ||
      action == WindowStreamControlAction.stop ||
      action == WindowStreamControlAction.error ||
      // One message, nothing follows on its session.
      action == WindowStreamControlAction.offer;

  WindowStreamControlMessage reply(
    WindowStreamControlAction action, {
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return WindowStreamControlMessage(
      action: action,
      sessionId: sessionId,
      viewerPeerId: viewerPeerId,
      hostPeerId: hostPeerId,
      payload: payload,
    );
  }

  WindowStreamControlMessage withTransport(String token, {int? port}) {
    return WindowStreamControlMessage(
      action: action,
      sessionId: sessionId,
      viewerPeerId: viewerPeerId,
      hostPeerId: hostPeerId,
      payload: payload,
      transportToken: token,
      transportPort: port,
    );
  }

  Map<String, Object?> toJson() => {
    'action': action.name,
    'sessionId': sessionId,
    'sourcePeerId': viewerPeerId,
    'sinkPeerId': hostPeerId,
    if (payload.isNotEmpty) 'payload': payload,
    if (_carriesToken(action)) 'transportToken': transportToken,
    if (transportPort != null) 'transportPort': transportPort,
  };

  static const allActions = {
    'browse',
    'catalog',
    'icon',
    'thumbnail',
    'open',
    'accept',
    'reject',
    'pause',
    'resume',
    'keyframe',
    'stop',
    'error',
    'offer',
    'viewport',
    'closeWindow',
    'closeResult',
    'dial',
  };
}

/// A window the host offers.
class RemoteWindowInfo {
  const RemoteWindowInfo({
    required this.id,
    required this.appId,
    required this.appName,
    required this.title,
    required this.width,
    required this.height,
    this.pid = 0,
    this.active = false,
    this.modal = false,
    this.viewerId,
    this.viewerName,
  });

  factory RemoteWindowInfo.fromJson(Map<String, Object?> json) {
    return RemoteWindowInfo(
      id: (json['id'] as num).toInt(),
      appId: json['bundleId'] as String? ?? json['appId'] as String? ?? '',
      appName: json['appName'] as String? ?? '',
      title: json['title'] as String? ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      pid: (json['pid'] as num?)?.toInt() ?? 0,
      active: json['active'] == true,
      modal: json['modal'] == true,
      viewerId: json['viewer'] is String ? json['viewer'] as String : null,
      viewerName: json['viewerName'] is String
          ? json['viewerName'] as String
          : null,
    );
  }

  final int id;
  final String appId;
  final String appName;
  final String title;
  final int width;
  final int height;
  final int pid;
  final bool active;

  /// The window shows a sheet or dialog of its own (an app asking whether
  /// to save), where the host's platform can tell.
  final bool modal;

  /// The peer the window is streaming to right now, and that device's name
  /// (a window is shown in one place at a time); null when it is not.
  final String? viewerId;
  final String? viewerName;

  Map<String, Object?> toJson() => {
    'id': id,
    'appId': appId,
    'appName': appName,
    'title': title,
    'width': width,
    'height': height,
    'active': active,
    if (modal) 'modal': true,
    if (viewerId != null) 'viewer': viewerId,
    if (viewerName != null) 'viewerName': viewerName,
  };
}

/// Packets on the `/window` media route, inside the authenticated envelope.
///
/// Host → viewer: `WWS1`, u8 type, u8 flags, u16 reserved, i64 pts µs, then
/// the payload (video: Annex-B H.264; size: u32 width, u32 height).
/// Viewer → host: `WWS1`, u8 type 10 (input), then i32 kind, code,
/// modifiers, phase; f64 x, y, dx, dy; u32 text length; UTF-8 text.
abstract final class WindowStreamPacket {
  static const List<int> magic = [0x57, 0x57, 0x53, 0x31]; // "WWS1"
  static const int headerBytes = 16;

  static const int typeVideo = 1;
  static const int typeSize = 2;

  /// Host → viewer, header only: sent when no video went out for a moment,
  /// so the viewer's Wi-Fi does not doze off between frames.
  static const int typeTick = 3;

  /// Host → viewer: the viewer's ping, echoed at once (round-trip time).
  static const int typePong = 4;

  /// Host → viewer, header only: the window's keyboard focus is somewhere
  /// to type ([flagTyping] set) or not.
  static const int typeTextFocus = 5;
  static const int flagTyping = 0x1;

  /// Host → viewer: how the sound that follows is coded. Payload: u8 codec
  /// ([audioOpus] or [audioPcm]), u8 channels, u16 frame ms, u32 sample
  /// rate. Only sent to viewers that asked for sound (`"audio": true` in
  /// their `open`); older viewers would not know the type.
  static const int typeAudioFormat = 6;

  /// Host → viewer: one frame of the window's sound in that format, pts on
  /// the video's clock.
  static const int typeAudio = 7;
  static const int audioOpus = 1;
  static const int audioPcm = 2;

  /// Largest audio frame accepted (60 ms of 48 kHz stereo PCM, with room).
  static const int maxAudioPayload = 32 * 1024;

  /// Viewer → host: header only plus the viewer's clock in the pts field.
  static const int typePing = 11;
  static const int typeInput = 10;

  static const int flagConfig = 0x1;
  static const int flagKey = 0x2;

  /// Largest video packet accepted (a 4K keyframe fits comfortably).
  static const int maxVideoPayload = 8 * 1024 * 1024;
  static const int maxInputText = 4096;

  static Uint8List video(
    Uint8List payload, {
    required int ptsUs,
    required int flags,
  }) {
    final out = Uint8List(headerBytes + payload.length);
    out.setRange(0, 4, magic);
    out[4] = typeVideo;
    out[5] = flags;
    ByteData.sublistView(out).setInt64(8, ptsUs);
    out.setRange(headerBytes, out.length, payload);
    return out;
  }

  static Uint8List audioFormat({
    required int codec,
    required int sampleRate,
    required int channels,
    required int frameMs,
  }) {
    final out = Uint8List(headerBytes + 8);
    out.setRange(0, 4, magic);
    out[4] = typeAudioFormat;
    ByteData.sublistView(out)
      ..setUint8(headerBytes, codec)
      ..setUint8(headerBytes + 1, channels)
      ..setUint16(headerBytes + 2, frameMs)
      ..setUint32(headerBytes + 4, sampleRate);
    return out;
  }

  static Uint8List audio(Uint8List payload, {required int ptsUs}) {
    final out = Uint8List(headerBytes + payload.length);
    out.setRange(0, 4, magic);
    out[4] = typeAudio;
    ByteData.sublistView(out).setInt64(8, ptsUs);
    out.setRange(headerBytes, out.length, payload);
    return out;
  }

  static Uint8List ping(int clockUs) => _stamped(typePing, clockUs);

  static Uint8List pong(int clockUs) => _stamped(typePong, clockUs);

  static Uint8List _stamped(int type, int clockUs) {
    final out = Uint8List(headerBytes);
    out.setRange(0, 4, magic);
    out[4] = type;
    ByteData.sublistView(out).setInt64(8, clockUs);
    return out;
  }

  static Uint8List textFocus({required bool typing}) {
    final out = Uint8List(headerBytes);
    out.setRange(0, 4, magic);
    out[4] = typeTextFocus;
    out[5] = typing ? flagTyping : 0;
    return out;
  }

  static Uint8List tick() {
    final out = Uint8List(headerBytes);
    out.setRange(0, 4, magic);
    out[4] = typeTick;
    return out;
  }

  static Uint8List size(int width, int height) {
    final out = Uint8List(headerBytes + 8);
    out.setRange(0, 4, magic);
    out[4] = typeSize;
    ByteData.sublistView(out)
      ..setUint32(headerBytes, width)
      ..setUint32(headerBytes + 4, height);
    return out;
  }

  static Uint8List input({
    required int kind,
    int code = 0,
    int modifiers = 0,
    int phase = 0,
    double x = 0,
    double y = 0,
    double dx = 0,
    double dy = 0,
    String? text,
  }) {
    final textBytes = text == null ? const <int>[] : utf8.encode(text);
    if (textBytes.length > maxInputText) {
      throw ArgumentError.value(text, 'text', 'too long');
    }
    final out = Uint8List(5 + 16 + 32 + 4 + textBytes.length);
    out.setRange(0, 4, magic);
    out[4] = typeInput;
    final data = ByteData.sublistView(out);
    data
      ..setInt32(5, kind)
      ..setInt32(9, code)
      ..setInt32(13, modifiers)
      ..setInt32(17, phase)
      ..setFloat64(21, x)
      ..setFloat64(29, y)
      ..setFloat64(37, dx)
      ..setFloat64(45, dy)
      ..setUint32(53, textBytes.length);
    out.setRange(57, out.length, textBytes);
    return out;
  }

  static WindowStreamPacketView decode(Uint8List bytes) {
    if (bytes.length < 5 ||
        bytes[0] != magic[0] ||
        bytes[1] != magic[1] ||
        bytes[2] != magic[2] ||
        bytes[3] != magic[3]) {
      throw const FormatException('not a window stream packet');
    }
    final type = bytes[4];
    final data = ByteData.sublistView(bytes);
    switch (type) {
      case typeVideo:
        if (bytes.length < headerBytes) {
          throw const FormatException('short video packet');
        }
        if (bytes.length - headerBytes > maxVideoPayload) {
          throw const FormatException('video packet too large');
        }
        return WindowStreamVideo(
          flags: bytes[5],
          ptsUs: data.getInt64(8),
          payload: Uint8List.sublistView(bytes, headerBytes),
        );
      case typeAudioFormat:
        if (bytes.length < headerBytes + 8) {
          throw const FormatException('short audio format packet');
        }
        final codec = data.getUint8(headerBytes);
        final channels = data.getUint8(headerBytes + 1);
        final sampleRate = data.getUint32(headerBytes + 4);
        if ((codec != audioOpus && codec != audioPcm) ||
            channels < 1 ||
            channels > 2 ||
            sampleRate < 8000 ||
            sampleRate > 96000) {
          throw const FormatException('bad audio format');
        }
        return WindowStreamAudioFormat(
          codec: codec,
          channels: channels,
          frameMs: data.getUint16(headerBytes + 2),
          sampleRate: sampleRate,
        );
      case typeAudio:
        if (bytes.length < headerBytes) {
          throw const FormatException('short audio packet');
        }
        if (bytes.length - headerBytes > maxAudioPayload) {
          throw const FormatException('audio packet too large');
        }
        return WindowStreamAudio(
          ptsUs: data.getInt64(8),
          payload: Uint8List.sublistView(bytes, headerBytes),
        );
      case typeTick:
        return const WindowStreamTick();
      case typeTextFocus:
        return WindowStreamTextFocus(typing: bytes[5] & flagTyping != 0);
      case typePing || typePong:
        if (bytes.length < headerBytes) {
          throw const FormatException('short ping packet');
        }
        final clockUs = data.getInt64(8);
        return type == typePing
            ? WindowStreamPing(clockUs)
            : WindowStreamPong(clockUs);
      case typeSize:
        if (bytes.length < headerBytes + 8) {
          throw const FormatException('short size packet');
        }
        return WindowStreamSize(
          data.getUint32(headerBytes),
          data.getUint32(headerBytes + 4),
        );
      case typeInput:
        if (bytes.length < 57) {
          throw const FormatException('short input packet');
        }
        final textLength = data.getUint32(53);
        if (textLength > maxInputText || bytes.length != 57 + textLength) {
          throw const FormatException('bad input text length');
        }
        return WindowStreamInput(
          kind: data.getInt32(5),
          code: data.getInt32(9),
          modifiers: data.getInt32(13),
          phase: data.getInt32(17),
          x: data.getFloat64(21),
          y: data.getFloat64(29),
          dx: data.getFloat64(37),
          dy: data.getFloat64(45),
          text: textLength == 0
              ? null
              : utf8.decode(
                  Uint8List.sublistView(bytes, 57),
                  allowMalformed: true,
                ),
        );
    }
    throw FormatException('unknown window stream packet type $type');
  }
}

sealed class WindowStreamPacketView {
  const WindowStreamPacketView();
}

class WindowStreamVideo extends WindowStreamPacketView {
  const WindowStreamVideo({
    required this.flags,
    required this.ptsUs,
    required this.payload,
  });

  final int flags;
  final int ptsUs;
  final Uint8List payload;

  bool get isConfig => flags & WindowStreamPacket.flagConfig != 0;
  bool get isKey => flags & WindowStreamPacket.flagKey != 0;
}

class WindowStreamAudioFormat extends WindowStreamPacketView {
  const WindowStreamAudioFormat({
    required this.codec,
    required this.channels,
    required this.frameMs,
    required this.sampleRate,
  });

  final int codec;
  final int channels;
  final int frameMs;
  final int sampleRate;
}

class WindowStreamAudio extends WindowStreamPacketView {
  const WindowStreamAudio({required this.ptsUs, required this.payload});

  final int ptsUs;
  final Uint8List payload;
}

class WindowStreamTick extends WindowStreamPacketView {
  const WindowStreamTick();
}

class WindowStreamTextFocus extends WindowStreamPacketView {
  const WindowStreamTextFocus({required this.typing});

  final bool typing;
}

class WindowStreamPing extends WindowStreamPacketView {
  const WindowStreamPing(this.clockUs);

  final int clockUs;
}

class WindowStreamPong extends WindowStreamPacketView {
  const WindowStreamPong(this.clockUs);

  final int clockUs;
}

class WindowStreamSize extends WindowStreamPacketView {
  const WindowStreamSize(this.width, this.height);

  final int width;
  final int height;
}

class WindowStreamInput extends WindowStreamPacketView {
  const WindowStreamInput({
    required this.kind,
    required this.code,
    required this.modifiers,
    required this.phase,
    required this.x,
    required this.y,
    required this.dx,
    required this.dy,
    this.text,
  });

  final int kind;
  final int code;
  final int modifiers;
  final int phase;
  final double x;
  final double y;
  final double dx;
  final double dy;
  final String? text;
}
