import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/framed_packet_codec.dart';

enum _Fruit { apple, banana }

void main() {
  test('json helpers tolerate bad input', () {
    expect(enumByName(_Fruit.values, 'banana', _Fruit.apple), _Fruit.banana);
    expect(enumByName(_Fruit.values, 'nope', _Fruit.apple), _Fruit.apple);
    expect(nullableEnumByName(_Fruit.values, 'nope'), isNull);
    expect(intJson('42'), 42);
    expect(intJson(null, 7), 7);
    expect(doubleJson(1, 0), 1.0);
  });
}
