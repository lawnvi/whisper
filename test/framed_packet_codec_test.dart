import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/framed_packet_codec.dart';

enum _Fruit { apple, banana }

void main() {
  test('encode/decode roundtrip preserves header order and payload', () {
    final bytes = encodeFramedPacket(
      magic: 'TST1',
      header: <String, dynamic>{'b': 2, 'a': 1, 'payloadLength': 2},
      payload: Uint8List.fromList([9, 8]),
    );
    final result =
        decodeFramedPacket(magic: 'TST1', label: 'test packet', bytes: bytes);
    expect(result.header.keys.toList(), ['b', 'a', 'payloadLength']);
    expect(result.payload, [9, 8]);
  });

  test('decode error messages follow the shared pattern', () {
    expect(
      () => decodeFramedPacket(
          magic: 'TST1',
          label: 'test packet',
          bytes: Uint8List.fromList([1])),
      throwsA(predicate((e) =>
          e is FormatException && e.message == 'test packet frame too short')),
    );
  });

  test('json helpers tolerate bad input', () {
    expect(enumByName(_Fruit.values, 'banana', _Fruit.apple), _Fruit.banana);
    expect(enumByName(_Fruit.values, 'nope', _Fruit.apple), _Fruit.apple);
    expect(nullableEnumByName(_Fruit.values, 'nope'), isNull);
    expect(intJson('42'), 42);
    expect(intJson(null, 7), 7);
    expect(doubleJson(1, 0), 1.0);
  });
}
