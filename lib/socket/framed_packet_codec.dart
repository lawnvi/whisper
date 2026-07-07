import 'dart:convert';
import 'dart:typed_data';

/// Shared wire skeleton for the framed packet protocols (audio / audio
/// group / remote input): `magic` ascii(4B) + big-endian uint32 header
/// length + JSON header (insertion order preserved) + raw payload bytes.
///
/// Extracted so the three `*PacketFrame` classes delegate to one
/// implementation instead of each carrying a byte-identical copy. The wire
/// format itself must stay unchanged — see test/framed_packet_golden_test.dart.
Uint8List encodeFramedPacket({
  required String magic,
  required Map<String, dynamic> header,
  required Uint8List payload,
}) {
  final headerBytes = utf8.encode(jsonEncode(header));
  final headerLength = ByteData(4)..setUint32(0, headerBytes.length);
  final bytes = BytesBuilder(copy: false)
    ..add(ascii.encode(magic))
    ..add(headerLength.buffer.asUint8List())
    ..add(headerBytes)
    ..add(payload);
  return bytes.takeBytes();
}

({Map<String, dynamic> header, Uint8List payload}) decodeFramedPacket({
  required String magic,
  required String label,
  required Uint8List bytes,
}) {
  if (bytes.length < 8) {
    throw FormatException('$label frame too short');
  }
  final actualMagic = ascii.decode(bytes.sublist(0, 4), allowInvalid: false);
  if (actualMagic != magic) {
    throw FormatException('invalid $label magic');
  }
  final headerLength = ByteData.sublistView(bytes, 4, 8).getUint32(0);
  final headerEnd = 8 + headerLength;
  if (bytes.length < headerEnd) {
    throw FormatException('$label header truncated');
  }
  final header = jsonDecode(
    utf8.decode(bytes.sublist(8, headerEnd)),
  ) as Map<String, dynamic>;
  final payload = Uint8List.sublistView(bytes, headerEnd);
  final expectedLength = header['payloadLength'] as int? ?? -1;
  if (payload.length != expectedLength) {
    throw FormatException('$label payload length mismatch');
  }
  return (header: header, payload: payload);
}

T enumByName<T extends Enum>(
  List<T> values,
  Object? raw,
  T fallback,
) {
  for (final value in values) {
    if (value.name == raw) {
      return value;
    }
  }
  return fallback;
}

T? nullableEnumByName<T extends Enum>(
  List<T> values,
  Object? raw,
) {
  if (raw == null) {
    return null;
  }
  for (final value in values) {
    if (value.name == raw) {
      return value;
    }
  }
  return null;
}

int intJson(Object? raw, [int fallback = 0]) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.round();
  }
  if (raw is String) {
    final parsed = num.tryParse(raw);
    if (parsed != null) {
      return parsed.round();
    }
  }
  return fallback;
}

double doubleJson(Object? raw, [double fallback = 0]) {
  if (raw is num) {
    return raw.toDouble();
  }
  if (raw is String) {
    final parsed = double.tryParse(raw);
    if (parsed != null) {
      return parsed;
    }
  }
  return fallback;
}
