import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

void main() {
  group('WhisperFrameV3', () {
    test('encodes and decodes a message frame', () {
      final frame = WhisperFrameV3(
        type: WhisperFrameType.message,
        transferId: '',
        offset: 0,
        sequence: 7,
        payload: Uint8List.fromList(utf8.encode('{"type":4}')),
      );

      final decoded = WhisperFrameV3.decode(frame.encode());

      expect(decoded.type, WhisperFrameType.message);
      expect(decoded.sequence, 7);
      expect(decoded.transferId, isEmpty);
      expect(utf8.decode(decoded.payload), '{"type":4}');
    });

    test('encodes and decodes a file data frame', () {
      final frame = WhisperFrameV3(
        type: WhisperFrameType.fileData,
        transferId: 'transfer-1',
        offset: 16 * 1024 * 1024,
        sequence: 42,
        payload: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );

      final decoded = WhisperFrameV3.decode(frame.encode());

      expect(decoded.type, WhisperFrameType.fileData);
      expect(decoded.transferId, 'transfer-1');
      expect(decoded.offset, 16 * 1024 * 1024);
      expect(decoded.sequence, 42);
      expect(decoded.payload, <int>[1, 2, 3, 4]);
    });

    test('rejects invalid magic and payload length mismatches', () {
      final encoded = WhisperFrameV3(
        type: WhisperFrameType.fileAck,
        transferId: 'transfer-1',
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(<int>[9, 8, 7]),
      ).encode();

      final badMagic = Uint8List.fromList(encoded);
      badMagic[0] = 0;
      expect(() => WhisperFrameV3.decode(badMagic), throwsFormatException);

      final badLength = Uint8List.fromList(encoded);
      final view = ByteData.sublistView(badLength);
      view.setUint32(12, 99);
      expect(() => WhisperFrameV3.decode(badLength), throwsFormatException);
    });
  });
}
