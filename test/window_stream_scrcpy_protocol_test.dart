import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/android/scrcpy/scrcpy_protocol.dart';

class _Packet {
  _Packet(this.length);

  final int length;
  final bytes = BytesBuilder();
  int? pts;
  bool? config;
  bool? key;
  bool discarded = false;
}

class _Writer implements MediaPacketWriter {
  _Writer(this.packet);

  final _Packet packet;

  @override
  void write(Uint8List chunk) => packet.bytes.add(chunk);

  @override
  void commit({required int ptsUs, required bool config, required bool key}) {
    packet.pts = ptsUs;
    packet.config = config;
    packet.key = key;
  }

  @override
  void discard() => packet.discarded = true;
}

class _Listener implements ScrcpyMediaListener {
  final codecs = <int>[];
  final sessions = <List<int>>[];
  final packets = <_Packet>[];

  @override
  void onCodec(int codecId) => codecs.add(codecId);

  @override
  void onSession(int width, int height) => sessions.add([width, height]);

  @override
  MediaPacketWriter beginPacket(int length) {
    final packet = _Packet(length);
    packets.add(packet);
    return _Writer(packet);
  }
}

Uint8List _header(int ptsAndFlags, int length) {
  final data = ByteData(12);
  data.setInt64(0, ptsAndFlags);
  data.setUint32(8, length);
  return data.buffer.asUint8List();
}

Uint8List _session(int width, int height) {
  final data = ByteData(12);
  data.setUint32(0, 0x80000000);
  data.setUint32(4, width);
  data.setUint32(8, height);
  return data.buffer.asUint8List();
}

void main() {
  group('ScrcpyControl encodes like scrcpy 5.0.1 ControlMessageReader', () {
    test('touch event layout', () {
      final bytes = ScrcpyControl.injectTouch(
        action: ScrcpyControl.actionDown,
        pointerId: ScrcpyControl.pointerIdGenericFinger,
        x: 540,
        y: 1200,
        screenWidth: 1080,
        screenHeight: 2400,
      );
      final data = ByteData.sublistView(bytes);
      expect(bytes.length, 32);
      expect(bytes[0], ScrcpyControl.typeInjectTouch);
      expect(bytes[1], ScrcpyControl.actionDown);
      expect(data.getInt64(2), -2);
      expect(data.getInt32(10), 540);
      expect(data.getInt32(14), 1200);
      expect(data.getUint16(18), 1080);
      expect(data.getUint16(20), 2400);
      expect(data.getUint16(22), 0xffff);
      expect(data.getInt32(24), 0);
      expect(data.getInt32(28), 0);
    });

    test('scroll uses i16 fixed point over a ±16 range', () {
      final bytes = ScrcpyControl.injectScroll(
        x: 10,
        y: 20,
        screenWidth: 100,
        screenHeight: 200,
        hScroll: -8,
        vScroll: 16,
      );
      final data = ByteData.sublistView(bytes);
      expect(bytes.length, 21);
      expect(data.getInt16(13), -0x4000);
      expect(data.getInt16(15), 0x7fff);
    });

    test('keycode, text, clipboard, start app, resize', () {
      final key = ByteData.sublistView(
        ScrcpyControl.injectKeycode(action: 1, keycode: 66, metaState: 0x1000),
      );
      expect(key.lengthInBytes, 14);
      expect(key.getUint8(0), 0);
      expect(key.getUint8(1), 1);
      expect(key.getInt32(2), 66);
      expect(key.getInt32(10), 0x1000);

      final text = ScrcpyControl.injectText('hi');
      expect(text, [1, 0, 0, 0, 2, 0x68, 0x69]);

      final clip = ScrcpyControl.setClipboard(
        sequence: 7,
        text: '你',
        paste: true,
      );
      final clipData = ByteData.sublistView(clip);
      expect(clip[0], 9);
      expect(clipData.getInt64(1), 7);
      expect(clip[9], 1);
      expect(clipData.getUint32(10), 3);
      expect(clip.length, 17);

      expect(ScrcpyControl.startApp('a.b'), [16, 3, 0x61, 0x2e, 0x62]);
      expect(ScrcpyControl.resizeDisplay(1080, 2400), [
        21,
        0x04,
        0x38,
        0x09,
        0x60,
      ]);
      expect(ScrcpyControl.resetVideo(), [17]);
      expect(ScrcpyControl.backOrScreenOn(0), [4, 0]);
    });

    test('fixed point helpers clamp', () {
      expect(ScrcpyControl.u16FixedPoint(1), 0xffff);
      expect(ScrcpyControl.u16FixedPoint(0.5), 0x8000);
      expect(ScrcpyControl.u16FixedPoint(-1), 0);
      expect(ScrcpyControl.i16FixedPoint(-1), -0x8000);
      expect(ScrcpyControl.i16FixedPoint(2), 0x7fff);
    });

    test('socket name is zero padded hex', () {
      expect(ScrcpyProtocol.socketName(0xabc), 'scrcpy_00000abc');
    });
  });

  group('ScrcpyMediaParser', () {
    test(
      'parses dummy byte, codec, session and packets split across chunks',
      () {
        final listener = _Listener();
        var dummy = 0;
        final parser = ScrcpyMediaParser(
          listener,
          expectDummyByte: true,
          onDummyByte: () => dummy++,
        );
        final config = Uint8List.fromList([
          0,
          0,
          0,
          1,
          0x67,
          1,
          2,
          0,
          0,
          0,
          1,
          0x68,
          3,
        ]);
        final frame = Uint8List.fromList(List.generate(300, (i) => i & 0xff));
        final stream = BytesBuilder()
          ..add([0])
          ..add([0x68, 0x32, 0x36, 0x34])
          ..add(_session(1080, 2400))
          ..add(_header(1 << 62, config.length))
          ..add(config)
          ..add(_header((1 << 61) | 123456, frame.length))
          ..add(frame)
          ..add(_header(123500, 2))
          ..add([9, 9]);
        final all = stream.takeBytes();
        // Feed in awkward chunk sizes.
        for (var offset = 0; offset < all.length; offset += 7) {
          parser.add(
            Uint8List.sublistView(
              all,
              offset,
              (offset + 7).clamp(0, all.length),
            ),
          );
        }
        expect(dummy, 1);
        expect(listener.codecs, [ScrcpyProtocol.codecH264]);
        expect(listener.sessions, [
          [1080, 2400],
        ]);
        expect(listener.packets, hasLength(3));
        expect(listener.packets[0].config, isTrue);
        expect(listener.packets[0].bytes.takeBytes(), config);
        expect(listener.packets[1].key, isTrue);
        expect(listener.packets[1].config, isFalse);
        expect(listener.packets[1].pts, 123456);
        expect(listener.packets[1].bytes.takeBytes(), frame);
        expect(listener.packets[2].key, isFalse);
        expect(listener.packets[2].pts, 123500);
      },
    );

    test('disabled stream stops parsing', () {
      final listener = _Listener();
      final parser = ScrcpyMediaParser(listener);
      parser.add(Uint8List.fromList([0, 0, 0, 0, 1, 2, 3]));
      expect(listener.codecs, [ScrcpyProtocol.streamDisabled]);
      expect(listener.packets, isEmpty);
    });

    test('close discards a partial packet', () {
      final listener = _Listener();
      final parser = ScrcpyMediaParser(listener);
      parser.add(Uint8List.fromList([0, 0x72, 0x61, 0x77]));
      parser.add(_header(5, 10));
      parser.add(Uint8List.fromList([1, 2, 3]));
      parser.close();
      expect(listener.packets.single.discarded, isTrue);
    });
  });

  test('device messages: clipboard across chunks and ack', () {
    final parser = ScrcpyDeviceMessageParser();
    final text = [0x68, 0x69];
    expect(parser.add([0, 0, 0]), isEmpty);
    final messages = parser.add([0, 2, ...text, 1, 0, 0, 0, 0, 0, 0, 0, 5]);
    expect(messages, hasLength(2));
    expect((messages[0] as ScrcpyClipboardMessage).text, 'hi');
    expect((messages[1] as ScrcpyClipboardAck).sequence, 5);
  });
}
