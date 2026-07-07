import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/wire_message_codec.dart';

MessageData _message(MessageEnum type) {
  return MessageData(
    id: 1,
    deviceId: null,
    sender: 'peer-a',
    receiver: 'peer-b',
    name: '',
    clipboard: false,
    size: 0,
    type: type,
    content: 'hello',
    message: '',
    timestamp: 1,
    uuid: 'msg-1',
    acked: true,
    path: '',
    md5: '',
    fileTimestamp: 0,
  );
}

void main() {
  test('encodes type as enum name string on the wire', () {
    final json =
        jsonDecode(encodeWireMessage(_message(MessageEnum.Text)))
            as Map<String, dynamic>;
    expect(json['type'], 'Text');
  });

  test('roundtrip keeps type and payload fields', () {
    final wire = encodeWireMessage(_message(MessageEnum.TransferControl));
    final decoded =
        decodeWireMessage(jsonDecode(wire) as Map<String, dynamic>);
    expect(decoded.type, MessageEnum.TransferControl);
    expect(decoded.uuid, 'msg-1');
    expect(decoded.content, 'hello');
    expect(decoded.sender, 'peer-a');
  });

  test('decodes legacy int index as fallback', () {
    final json = jsonDecode(encodeWireMessage(_message(MessageEnum.Text)))
        as Map<String, dynamic>;
    json['type'] = MessageEnum.Text.index;
    expect(decodeWireMessage(json).type, MessageEnum.Text);
  });

  test('unknown name, out-of-range index and null degrade to UNKONWN', () {
    expect(messageEnumFromWire('NotAType'), MessageEnum.UNKONWN);
    expect(messageEnumFromWire(999), MessageEnum.UNKONWN);
    expect(messageEnumFromWire(-1), MessageEnum.UNKONWN);
    expect(messageEnumFromWire(null), MessageEnum.UNKONWN);
    expect(messageEnumFromWire(MessageEnum.Auth.name), MessageEnum.Auth);
  });
}
