import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:whisper/model/device.dart';

// dart run build_runner build
class Message extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get deviceId =>
      integer().named("device_id").nullable().references(Device, #id)();
  TextColumn get sender => text().withDefault(const Constant(""))();
  TextColumn get receiver => text().withDefault(const Constant(""))();
  TextColumn get name => text().withDefault(const Constant(""))();
  BoolColumn get clipboard => boolean().withDefault(const Constant(false))();
  IntColumn get size => integer().withDefault(const Constant(0))();
  IntColumn get type => intEnum<MessageEnum>().withDefault(const Constant(0))();
  TextColumn get content => text().nullable().withDefault(const Constant(""))();
  TextColumn get message => text().nullable().withDefault(const Constant(""))();
  IntColumn get timestamp => integer().withDefault(const Constant(0))();
  TextColumn get uuid => text().withDefault(const Constant(""))();
  BoolColumn get acked => boolean().withDefault(const Constant(false))();
  TextColumn get path => text().withDefault(const Constant(""))();
  TextColumn get md5 => text().withDefault(const Constant(""))();
  IntColumn get fileTimestamp =>
      integer().nullable().withDefault(const Constant(0))();
}

enum MessageEnum {
  UNKONWN,
  Ack,
  Auth,
  Heartbeat,
  Text,
  File,
  FileSignal,
  Notification,
  TransferControl,
}

class FileSignal {
  String msgId = ""; // 消息id
  int size = 0; // 文件大小
  int received = 0; // 已接受大小

  FileSignal(this.size, this.received, this.msgId);

  FileSignal.fromJson(Map<String, dynamic> json)
      : msgId = json['msg_id'] as String,
        size = json['size'] as int,
        received = json['received'] as int;

  Map<String, dynamic> toJson() => {
        'msg_id': msgId,
        'size': size,
        'received': received,
      };
}

enum TransferAction {
  resumeProbe,
  ready,
  restart,
  progress,
  complete,
  pause,
  cancel,
  error,
}

class TransferControl {
  TransferControl({
    required this.action,
    required this.transferId,
    required this.name,
    required this.size,
    required this.fileTimestamp,
    required this.checksumAlgorithm,
    required this.checksumValue,
    required this.chunkSize,
    required this.resumeOffset,
    required this.resumeProofHash,
    required this.errorCode,
    required this.errorMessage,
  });

  final TransferAction action;
  final String transferId;
  final String name;
  final int size;
  final int fileTimestamp;
  final String checksumAlgorithm;
  final String checksumValue;
  final int chunkSize;
  final int resumeOffset;
  final String resumeProofHash;
  final String errorCode;
  final String errorMessage;

  factory TransferControl.fromJson(Map<String, dynamic> json) {
    final actionName = json['action'] as String? ?? TransferAction.error.name;
    final action = TransferAction.values.firstWhere(
      (item) => item.name == actionName,
      orElse: () => TransferAction.error,
    );
    return TransferControl(
      action: action,
      transferId: json['transferId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      fileTimestamp: json['fileTimestamp'] as int? ?? 0,
      checksumAlgorithm: json['checksumAlgorithm'] as String? ?? '',
      checksumValue: json['checksumValue'] as String? ?? '',
      chunkSize: json['chunkSize'] as int? ?? 0,
      resumeOffset: json['resumeOffset'] as int? ?? 0,
      resumeProofHash: json['resumeProofHash'] as String? ?? '',
      errorCode: json['errorCode'] as String? ?? '',
      errorMessage: json['errorMessage'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'action': action.name,
        'transferId': transferId,
        'name': name,
        'size': size,
        'fileTimestamp': fileTimestamp,
        'checksumAlgorithm': checksumAlgorithm,
        'checksumValue': checksumValue,
        'chunkSize': chunkSize,
        'resumeOffset': resumeOffset,
        'resumeProofHash': resumeProofHash,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
      };
}

class TransferChunkFrame {
  TransferChunkFrame({
    required this.transferId,
    required this.offset,
    required this.payload,
    int? payloadLength,
    this.payloadInNextFrame = false,
    this.payloadChecksum = '',
  }) : payloadLength = payloadLength ?? payload.length;

  static const String magic = 'WSP2';

  final String transferId;
  final int offset;
  final Uint8List payload;
  final int payloadLength;
  final bool payloadInNextFrame;
  final String payloadChecksum;

  static bool looksLikeFrame(Uint8List bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x57 &&
        bytes[1] == 0x53 &&
        bytes[2] == 0x50 &&
        bytes[3] == 0x32;
  }

  Uint8List encode() {
    final header = utf8.encode(jsonEncode({
      'transferId': transferId,
      'offset': offset,
      'length': payloadLength,
      if (payloadInNextFrame) 'payloadInNextFrame': true,
      if (payloadChecksum.isNotEmpty) 'payloadChecksum': payloadChecksum,
    }));
    final bytes = BytesBuilder(copy: false)..add(ascii.encode(magic));
    final headerLength = ByteData(4)..setUint32(0, header.length);
    bytes
      ..add(headerLength.buffer.asUint8List())
      ..add(header)
      ..add(payloadInNextFrame ? Uint8List(0) : payload);
    return bytes.takeBytes();
  }

  factory TransferChunkFrame.decode(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const FormatException('chunk frame too short');
    }
    final actualMagic = ascii.decode(bytes.sublist(0, 4), allowInvalid: false);
    if (actualMagic != magic) {
      throw const FormatException('invalid resumable transfer magic');
    }
    final headerLength = ByteData.sublistView(bytes, 4, 8).getUint32(0);
    final headerEnd = 8 + headerLength;
    if (bytes.length < headerEnd) {
      throw const FormatException('chunk header truncated');
    }
    final header = jsonDecode(
      utf8.decode(bytes.sublist(8, headerEnd)),
    ) as Map<String, dynamic>;
    final payload = Uint8List.sublistView(bytes, headerEnd);
    final expectedLength = header['length'] as int? ?? -1;
    final payloadInNextFrame = header['payloadInNextFrame'] == true;
    if (payloadInNextFrame && payload.isNotEmpty) {
      throw const FormatException('chunk header frame contains payload');
    }
    if (!payloadInNextFrame && payload.length != expectedLength) {
      throw const FormatException('chunk payload length mismatch');
    }
    return TransferChunkFrame(
      transferId: header['transferId'] as String? ?? '',
      offset: header['offset'] as int? ?? 0,
      payload: payload,
      payloadLength: expectedLength,
      payloadInNextFrame: payloadInNextFrame,
      payloadChecksum: header['payloadChecksum'] as String? ?? '',
    );
  }
}
