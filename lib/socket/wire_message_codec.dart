import 'dart:convert';

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';

/// wire 上顶层消息 type 以枚举名字符串传输(2026-07-07 spec:不兼容旧版本)。
/// 解码容忍旧 int 序号与非法值,降级 UNKONWN;int 回退仅为缓解开发期新旧
/// debug 包混装窗口,不是兼容承诺。
MessageEnum messageEnumFromWire(Object? raw) {
  if (raw is String) {
    for (final value in MessageEnum.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return MessageEnum.UNKONWN;
  }
  if (raw is int && raw >= 0 && raw < MessageEnum.values.length) {
    return MessageEnum.values[raw];
  }
  return MessageEnum.UNKONWN;
}

String encodeWireMessage(MessageData message) {
  final json = message.toJson();
  json['type'] = message.type.name;
  return jsonEncode(json);
}

MessageData decodeWireMessage(Map<String, dynamic> json) {
  final normalized = Map<String, dynamic>.from(json);
  normalized['type'] = messageEnumFromWire(json['type']).index;
  return MessageData.fromJson(normalized);
}
