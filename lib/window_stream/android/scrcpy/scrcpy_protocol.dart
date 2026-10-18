import 'dart:convert';
import 'dart:typed_data';

import '../../core/media_packet.dart';

export '../../core/media_packet.dart';

/// Wire format of the bundled stock scrcpy-server. Pinned to this version:
/// the server refuses clients that pass a different version string.
abstract final class ScrcpyProtocol {
  static const String serverVersion = '5.0.1';
  static const String serverClass = 'com.genymobile.scrcpy.Server';

  static const int codecH264 = 0x68323634;
  static const int codecH265 = 0x68323635;
  static const int codecAv1 = 0x00617631;
  static const int codecOpus = 0x6f707573;
  static const int codecAac = 0x00616163;
  static const int codecFlac = 0x666c6163;
  static const int codecRaw = 0x00726177;

  /// Codec-id values meaning "stream disabled" / "configuration error".
  static const int streamDisabled = 0;
  static const int streamError = 1;

  /// Socket name for a session id (scid), e.g. `scrcpy_0a1b2c3d`.
  static String socketName(int scid) =>
      'scrcpy_${scid.toRadixString(16).padLeft(8, '0')}';
}

/// Client-to-server control messages (see scrcpy ControlMessageReader).
abstract final class ScrcpyControl {
  static const int typeInjectKeycode = 0;
  static const int typeInjectText = 1;
  static const int typeInjectTouch = 2;
  static const int typeInjectScroll = 3;
  static const int typeBackOrScreenOn = 4;
  static const int typeGetClipboard = 8;
  static const int typeSetClipboard = 9;
  static const int typeSetDisplayPower = 10;
  static const int typeStartApp = 16;
  static const int typeResetVideo = 17;
  static const int typeResizeDisplay = 21;

  static const int actionDown = 0;
  static const int actionUp = 1;
  static const int actionMove = 2;
  static const int actionCancel = 3;

  /// Pointer ids understood by the server: the mouse, and a generic finger
  /// (injected as a touchscreen event, which apps treat as a real touch).
  static const int pointerIdMouse = -1;
  static const int pointerIdGenericFinger = -2;

  /// Android KeyEvent meta state bits.
  static const int metaShift = 0x1;
  static const int metaAlt = 0x2;
  static const int metaCtrl = 0x1000;
  static const int metaMeta = 0x10000;

  /// Text injection is limited server-side.
  static const int injectTextMaxLength = 300;

  static Uint8List injectKeycode({
    required int action,
    required int keycode,
    int repeat = 0,
    int metaState = 0,
  }) {
    final data = ByteData(14);
    data.setUint8(0, typeInjectKeycode);
    data.setUint8(1, action);
    data.setInt32(2, keycode);
    data.setInt32(6, repeat);
    data.setInt32(10, metaState);
    return data.buffer.asUint8List();
  }

  static Uint8List injectText(String text) {
    final bytes = utf8.encode(text);
    final data = ByteData(5 + bytes.length);
    data.setUint8(0, typeInjectText);
    data.setUint32(1, bytes.length);
    final out = data.buffer.asUint8List();
    out.setRange(5, out.length, bytes);
    return out;
  }

  static Uint8List injectTouch({
    required int action,
    required int pointerId,
    required int x,
    required int y,
    required int screenWidth,
    required int screenHeight,
    double pressure = 1,
    int actionButton = 0,
    int buttons = 0,
  }) {
    final data = ByteData(32);
    data.setUint8(0, typeInjectTouch);
    data.setUint8(1, action);
    data.setInt64(2, pointerId);
    data.setInt32(10, x);
    data.setInt32(14, y);
    data.setUint16(18, screenWidth);
    data.setUint16(20, screenHeight);
    data.setUint16(22, u16FixedPoint(pressure));
    data.setInt32(24, actionButton);
    data.setInt32(28, buttons);
    return data.buffer.asUint8List();
  }

  /// [hScroll] and [vScroll] are in "wheel notches", clamped to ±16.
  static Uint8List injectScroll({
    required int x,
    required int y,
    required int screenWidth,
    required int screenHeight,
    required double hScroll,
    required double vScroll,
    int buttons = 0,
  }) {
    final data = ByteData(21);
    data.setUint8(0, typeInjectScroll);
    data.setInt32(1, x);
    data.setInt32(5, y);
    data.setUint16(9, screenWidth);
    data.setUint16(11, screenHeight);
    data.setInt16(13, i16FixedPoint(hScroll / 16));
    data.setInt16(15, i16FixedPoint(vScroll / 16));
    data.setInt32(17, buttons);
    return data.buffer.asUint8List();
  }

  static Uint8List backOrScreenOn(int action) {
    return Uint8List.fromList([typeBackOrScreenOn, action]);
  }

  static Uint8List getClipboard({int copyKey = 0}) {
    return Uint8List.fromList([typeGetClipboard, copyKey]);
  }

  static Uint8List setClipboard({
    required int sequence,
    required String text,
    bool paste = false,
  }) {
    final bytes = utf8.encode(text);
    final data = ByteData(14 + bytes.length);
    data.setUint8(0, typeSetClipboard);
    data.setInt64(1, sequence);
    data.setUint8(9, paste ? 1 : 0);
    data.setUint32(10, bytes.length);
    final out = data.buffer.asUint8List();
    out.setRange(14, out.length, bytes);
    return out;
  }

  static Uint8List setDisplayPower({required bool on}) {
    return Uint8List.fromList([typeSetDisplayPower, on ? 1 : 0]);
  }

  /// [name] is a package name, optionally prefixed with `+` (force-stop
  /// first). The length prefix is one byte.
  static Uint8List startApp(String name) {
    final bytes = utf8.encode(name);
    if (bytes.length > 255) {
      throw ArgumentError.value(name, 'name', 'too long');
    }
    return Uint8List.fromList([typeStartApp, bytes.length, ...bytes]);
  }

  static Uint8List resetVideo() => Uint8List.fromList([typeResetVideo]);

  static Uint8List resizeDisplay(int width, int height) {
    final data = ByteData(5);
    data.setUint8(0, typeResizeDisplay);
    data.setUint16(1, width);
    data.setUint16(3, height);
    return data.buffer.asUint8List();
  }

  /// [0, 1] → u16 fixed point, as scrcpy's sc_float_to_u16fp.
  static int u16FixedPoint(double value) {
    final scaled = (value.clamp(0.0, 1.0) * 0x10000).toInt();
    return scaled > 0xffff ? 0xffff : scaled;
  }

  /// [-1, 1] → i16 fixed point, as scrcpy's sc_float_to_i16fp.
  static int i16FixedPoint(double value) {
    final scaled = (value.clamp(-1.0, 1.0) * 0x8000).toInt();
    if (scaled > 0x7fff) {
      return 0x7fff;
    }
    if (scaled < -0x8000) {
      return -0x8000;
    }
    return scaled;
  }
}

/// Server-to-client messages on the control socket.
sealed class ScrcpyDeviceMessage {
  const ScrcpyDeviceMessage();
}

class ScrcpyClipboardMessage extends ScrcpyDeviceMessage {
  const ScrcpyClipboardMessage(this.text);

  final String text;
}

class ScrcpyClipboardAck extends ScrcpyDeviceMessage {
  const ScrcpyClipboardAck(this.sequence);

  final int sequence;
}

class ScrcpyUhidOutput extends ScrcpyDeviceMessage {
  const ScrcpyUhidOutput(this.id, this.data);

  final int id;
  final Uint8List data;
}

/// Incrementally parses device messages from control-socket bytes.
class ScrcpyDeviceMessageParser {
  final _buffer = BytesBuilder(copy: true);

  List<ScrcpyDeviceMessage> add(List<int> chunk) {
    _buffer.add(chunk);
    final bytes = _buffer.takeBytes();
    final messages = <ScrcpyDeviceMessage>[];
    var offset = 0;
    while (offset < bytes.length) {
      final consumed = _tryParse(bytes, offset, messages);
      if (consumed == 0) {
        break;
      }
      offset += consumed;
    }
    if (offset < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, offset));
    }
    return messages;
  }

  static int _tryParse(
    Uint8List bytes,
    int offset,
    List<ScrcpyDeviceMessage> out,
  ) {
    final remaining = bytes.length - offset;
    final data = ByteData.sublistView(bytes, offset);
    switch (bytes[offset]) {
      case 0: // clipboard
        if (remaining < 5) {
          return 0;
        }
        final length = data.getUint32(1);
        if (remaining < 5 + length) {
          return 0;
        }
        out.add(
          ScrcpyClipboardMessage(
            utf8.decode(
              Uint8List.sublistView(bytes, offset + 5, offset + 5 + length),
              allowMalformed: true,
            ),
          ),
        );
        return 5 + length;
      case 1: // ack clipboard
        if (remaining < 9) {
          return 0;
        }
        out.add(ScrcpyClipboardAck(data.getInt64(1)));
        return 9;
      case 2: // uhid output
        if (remaining < 5) {
          return 0;
        }
        final length = data.getUint16(3);
        if (remaining < 5 + length) {
          return 0;
        }
        out.add(
          ScrcpyUhidOutput(
            data.getUint16(1),
            Uint8List.fromList(
              Uint8List.sublistView(bytes, offset + 5, offset + 5 + length),
            ),
          ),
        );
        return 5 + length;
      default:
        throw FormatException('unknown scrcpy device message ${bytes[offset]}');
    }
  }
}

/// Callbacks of [ScrcpyMediaParser].
abstract interface class ScrcpyMediaListener {
  void onCodec(int codecId);

  /// Session metadata (video only): the frame size changed.
  void onSession(int width, int height);

  /// Called with the packet length; return a writer for its payload.
  MediaPacketWriter beginPacket(int length);
}

/// Push parser for one scrcpy media socket (video or audio): optional dummy
/// byte, 4-byte codec id, then 12-byte headers each followed by a payload or
/// (for session metadata) nothing.
class ScrcpyMediaParser {
  ScrcpyMediaParser(
    this._listener, {
    bool expectDummyByte = false,
    void Function()? onDummyByte,
  }) : _state = expectDummyByte ? _State.dummy : _State.codec,
       _onDummyByte = onDummyByte;

  final void Function()? _onDummyByte;

  static const int _flagSession = 1 << 63;
  static const int _flagConfig = 1 << 62;
  static const int _flagKey = 1 << 61;
  static const int _ptsMask = _flagKey - 1;

  final ScrcpyMediaListener _listener;
  _State _state;
  final _header = Uint8List(12);
  int _headerFill = 0;
  int _payloadRemaining = 0;
  MediaPacketWriter? _writer;
  int _pts = 0;
  bool _config = false;
  bool _key = false;

  /// Feeds socket bytes. Never copies payload bytes except into the writer.
  void add(Uint8List chunk) {
    var offset = 0;
    while (offset < chunk.length) {
      switch (_state) {
        case _State.dummy:
          offset += 1;
          _state = _State.codec;
          _onDummyByte?.call();
        case _State.codec:
          offset += _fillHeader(chunk, offset, 4);
          if (_headerFill == 4) {
            final codec = ByteData.sublistView(_header, 0, 4).getUint32(0);
            _headerFill = 0;
            _listener.onCodec(codec);
            _state =
                (codec == ScrcpyProtocol.streamDisabled ||
                    codec == ScrcpyProtocol.streamError)
                ? _State.ended
                : _State.header;
          }
        case _State.header:
          offset += _fillHeader(chunk, offset, 12);
          if (_headerFill == 12) {
            _headerFill = 0;
            _onHeader();
          }
        case _State.payload:
          final take = (chunk.length - offset).clamp(0, _payloadRemaining);
          _writer!.write(Uint8List.sublistView(chunk, offset, offset + take));
          offset += take;
          _payloadRemaining -= take;
          if (_payloadRemaining == 0) {
            final writer = _writer!;
            _writer = null;
            _state = _State.header;
            writer.commit(ptsUs: _pts, config: _config, key: _key);
          }
        case _State.ended:
          return;
      }
    }
  }

  int _fillHeader(Uint8List chunk, int offset, int size) {
    final take = (chunk.length - offset).clamp(0, size - _headerFill);
    _header.setRange(_headerFill, _headerFill + take, chunk, offset);
    _headerFill += take;
    return take;
  }

  void _onHeader() {
    final data = ByteData.sublistView(_header);
    final ptsAndFlags = data.getInt64(0);
    if (ptsAndFlags & _flagSession != 0) {
      _listener.onSession(data.getUint32(4), data.getUint32(8));
      return;
    }
    final length = data.getUint32(8);
    _config = ptsAndFlags & _flagConfig != 0;
    _key = ptsAndFlags & _flagKey != 0;
    _pts = _config ? 0 : ptsAndFlags & _ptsMask;
    if (length == 0) {
      return;
    }
    _payloadRemaining = length;
    _writer = _listener.beginPacket(length);
    _state = _State.payload;
  }

  /// The socket closed: drop any partial packet.
  void close() {
    _writer?.discard();
    _writer = null;
    _state = _State.ended;
  }
}

enum _State { dummy, codec, header, payload, ended }
