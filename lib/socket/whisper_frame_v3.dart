import 'dart:convert';
import 'dart:typed_data';

enum WhisperFrameType {
  message(1),
  fileOffer(2),
  fileReady(3),
  fileData(4),
  fileAck(5),
  fileComplete(6),
  fileCancel(7),
  fileError(8),
  clipboardOffer(9),
  clipboardRequest(10),
  clipboardData(11),
  clipboardComplete(12),
  clipboardClear(13),
  clipboardError(14);

  const WhisperFrameType(this.code);

  final int code;

  static WhisperFrameType fromCode(int code) {
    return WhisperFrameType.values.firstWhere(
      (item) => item.code == code,
      orElse: () => throw FormatException('unknown whisper frame type $code'),
    );
  }
}

class WhisperFrameV3 {
  WhisperFrameV3({
    required this.type,
    required this.transferId,
    required this.offset,
    required this.sequence,
    required this.payload,
    this.flags = 0,
  }) {
    if (transferIdBytes.length > transferIdFieldLength) {
      throw ArgumentError('transferId is too long');
    }
  }

  static const int version = 3;
  static const String magic = 'WFR3';
  static const int transferIdFieldLength = 64;
  static const int headerLength = 96;

  final WhisperFrameType type;
  final String transferId;
  final int offset;
  final int sequence;
  final int flags;
  final Uint8List payload;

  Uint8List get transferIdBytes => Uint8List.fromList(utf8.encode(transferId));

  static bool looksLikeFrame(Uint8List bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x57 &&
        bytes[1] == 0x46 &&
        bytes[2] == 0x52 &&
        bytes[3] == 0x33;
  }

  Uint8List encode() {
    final bytes = Uint8List(headerLength + payload.length);
    writeHeaderInto(bytes);
    bytes.setRange(headerLength, bytes.length, payload);
    return bytes;
  }

  void writeHeaderInto(Uint8List bytes, {int destinationOffset = 0}) {
    if (destinationOffset < 0 ||
        bytes.length - destinationOffset < headerLength + payload.length) {
      throw RangeError('Whisper frame destination is too small');
    }
    final view = ByteData.sublistView(
      bytes,
      destinationOffset,
      destinationOffset + headerLength,
    );
    final magicBytes = ascii.encode(magic);
    bytes.setRange(
      destinationOffset,
      destinationOffset + magicBytes.length,
      magicBytes,
    );
    view
      ..setUint8(4, version)
      ..setUint8(5, type.code)
      ..setUint16(6, flags)
      ..setUint32(8, headerLength)
      ..setUint32(12, payload.length)
      ..setUint64(16, offset)
      ..setUint32(24, sequence)
      ..setUint32(28, 0);
    final idBytes = transferIdBytes;
    bytes.setRange(
      destinationOffset + 32,
      destinationOffset + 32 + idBytes.length,
      idBytes,
    );
  }

  factory WhisperFrameV3.decode(Uint8List bytes) {
    if (bytes.length < headerLength) {
      throw const FormatException('whisper frame too short');
    }
    if (!looksLikeFrame(bytes)) {
      throw const FormatException('invalid whisper frame magic');
    }
    final view = ByteData.sublistView(bytes);
    final actualVersion = view.getUint8(4);
    if (actualVersion != version) {
      throw FormatException('unsupported whisper frame version $actualVersion');
    }
    final actualHeaderLength = view.getUint32(8);
    if (actualHeaderLength != headerLength) {
      throw FormatException('invalid whisper frame header $actualHeaderLength');
    }
    final payloadLength = view.getUint32(12);
    if (bytes.length != headerLength + payloadLength) {
      throw const FormatException('whisper frame payload length mismatch');
    }
    final idBytes = bytes
        .sublist(32, 32 + transferIdFieldLength)
        .takeWhile((byte) => byte != 0)
        .toList(growable: false);
    return WhisperFrameV3(
      type: WhisperFrameType.fromCode(view.getUint8(5)),
      transferId: utf8.decode(idBytes),
      offset: view.getUint64(16),
      sequence: view.getUint32(24),
      flags: view.getUint16(6),
      payload: Uint8List.sublistView(bytes, headerLength),
    );
  }
}
