import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

/// wire 黄金字节锁:magic + uint32BE len + JSON header(字段插入序)+ payload。
/// 本文件断言在 transport/codec 收敛重构(C 组)前后必须逐字节成立,不许修改。
void _expectLayout(
  Uint8List bytes, {
  required String magic,
  required String headerJson,
  required List<int> payload,
}) {
  expect(ascii.decode(bytes.sublist(0, 4)), magic);
  final headerLen = ByteData.sublistView(bytes, 4, 8).getUint32(0);
  expect(headerLen, utf8.encode(headerJson).length);
  expect(utf8.decode(bytes.sublist(8, 8 + headerLen)), headerJson);
  expect(bytes.sublist(8 + headerLen), payload);
}

void main() {
  final payload = Uint8List.fromList([1, 2, 3]);

  test('WSA1 audio packet frame golden bytes', () {
    final bytes = AudioPacketFrame(
      sessionId: 'sess-1',
      sequence: 7,
      captureTimeMicros: 123456,
      payload: payload,
    ).encode();
    _expectLayout(
      bytes,
      magic: 'WSA1',
      headerJson:
          '{"sessionId":"sess-1","sequence":7,"captureTimeMicros":123456,"payloadLength":3}',
      payload: [1, 2, 3],
    );
    final decoded = AudioPacketFrame.decode(bytes);
    expect(decoded.sessionId, 'sess-1');
    expect(decoded.sequence, 7);
    expect(decoded.captureTimeMicros, 123456);
    expect(decoded.payload, [1, 2, 3]);
  });

  test('WSG1 audio group packet frame golden bytes', () {
    final bytes = AudioGroupPacketFrame(
      groupId: 'g-1',
      streamId: 'st-1',
      sessionId: 'sess-1',
      sourcePeerId: 'peer-a',
      sequence: 7,
      captureTimeMicros: 123456,
      targetPlaybackTimeMicros: 234567,
      durationMicros: 20000,
      channelMask: AudioChannelMask.stereo,
      payload: payload,
    ).encode();
    _expectLayout(
      bytes,
      magic: 'WSG1',
      headerJson:
          '{"groupId":"g-1","streamId":"st-1","sessionId":"sess-1","sourcePeerId":"peer-a","sequence":7,"captureTimeMicros":123456,"targetPlaybackTimeMicros":234567,"durationMicros":20000,"channelMask":"stereo","payloadLength":3}',
      payload: [1, 2, 3],
    );
    final decoded = AudioGroupPacketFrame.decode(bytes);
    expect(decoded.groupId, 'g-1');
    expect(decoded.channelMask, AudioChannelMask.stereo);
    expect(decoded.payload, [1, 2, 3]);
  });

  test('WRI1 remote input packet frame golden bytes', () {
    final bytes = RemoteInputPacketFrame(
      sessionId: 'sess-1',
      sequence: 7,
      timestampMicros: 123456,
      eventType: RemoteInputEventType.release,
      payload: payload,
    ).encode();
    _expectLayout(
      bytes,
      magic: 'WRI1',
      headerJson:
          '{"sessionId":"sess-1","sequence":7,"timestampMicros":123456,"eventType":"release","payloadLength":3}',
      payload: [1, 2, 3],
    );
    final decoded = RemoteInputPacketFrame.decode(bytes);
    expect(decoded.eventType, RemoteInputEventType.release);
    expect(decoded.payload, [1, 2, 3]);
  });

  test('decode errors keep exact messages', () {
    expect(
      () => AudioPacketFrame.decode(Uint8List.fromList([1, 2])),
      throwsA(predicate((e) =>
          e is FormatException && e.message == 'audio packet frame too short')),
    );
    final wrongMagic = Uint8List.fromList([...ascii.encode('XXXX'), 0, 0, 0, 0]);
    expect(
      () => AudioGroupPacketFrame.decode(wrongMagic),
      throwsA(predicate((e) =>
          e is FormatException &&
          e.message == 'invalid audio group packet magic')),
    );
    expect(
      () => RemoteInputPacketFrame.decode(wrongMagic),
      throwsA(predicate((e) =>
          e is FormatException &&
          e.message == 'invalid remote input packet magic')),
    );
  });
}
