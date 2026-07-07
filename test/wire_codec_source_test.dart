import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// wire 编解码必须统一走 wire_message_codec,svrmanager 不得再有
/// MessageData 的 toJsonString 直发与 MessageData.fromJson 直收。
void main() {
  final source = File('lib/socket/svrmanager.dart').readAsStringSync();

  test('all MessageData wire encodes go through encodeWireMessage', () {
    expect(source.contains('message.toJsonString()'), isFalse,
        reason: 'MessageData 编码必须走 encodeWireMessage');
    expect(source.contains('encodeWireMessage('), isTrue);
    // PeerProfile 载荷不受影响
    expect(source.contains('profile.toJsonString()'), isTrue);
  });

  test('all MessageData wire decodes go through decodeWireMessage', () {
    expect(source.contains('MessageData.fromJson('), isFalse,
        reason: 'MessageData 解码必须走 decodeWireMessage');
    expect(source.contains('decodeWireMessage('), isTrue);
  });
}
