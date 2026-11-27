import 'dart:convert';
import 'dart:typed_data';

import 'package:whisper/socket/bounded_outbound_queue.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

typedef OutboundFrameClassification = ({
  OutboundPacketKind kind,
  bool waitForSpace,
});

Uint8List? outgoingPayloadBytes(Object message) => switch (message) {
  Uint8List b => b,
  List<int> b => Uint8List.fromList(b),
  String s => Uint8List.fromList(utf8.encode(s)),
  _ => null,
};

Uint8List encodeMessageFrame(Uint8List payload) => WhisperFrameV3(
  type: WhisperFrameType.message,
  transferId: '',
  offset: 0,
  sequence: 0,
  payload: payload,
).encode();

/// Classifies an encoded [WhisperFrameV3] payload by inspecting its fixed
/// header type byte (offset 5) without re-allocating or parsing JSON.
///
/// Control frames stay fail-closed and return immediately on admission;
/// mount data frames and bulk data frames wait for outbound queue space
/// instead of tearing down the connection.
OutboundFrameClassification classifyOutboundFrame(Uint8List bytes) {
  if (bytes.length < WhisperFrameV3.headerLength ||
      !WhisperFrameV3.looksLikeFrame(bytes)) {
    return (kind: OutboundPacketKind.control, waitForSpace: false);
  }
  final code = bytes[5];
  if (code == WhisperFrameType.browseData.code ||
      code == WhisperFrameType.browseWrite.code) {
    return (kind: OutboundPacketKind.mount, waitForSpace: true);
  }
  if (code == WhisperFrameType.fileData.code) {
    return (kind: OutboundPacketKind.file, waitForSpace: true);
  }
  return (kind: OutboundPacketKind.control, waitForSpace: false);
}
