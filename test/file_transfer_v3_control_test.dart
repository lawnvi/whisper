import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/file_transfer_v3.dart';

void main() {
  group('FileTransferV3Control', () {
    test('round-trips ready and ack controls', () {
      final ready = FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: 'transfer-1',
        durableOffset: 16 * 1024 * 1024,
        size: 64 * 1024 * 1024,
        errorCode: '',
        errorMessage: '',
      );

      final decoded = FileTransferV3Control.fromJson(ready.toJson());

      expect(decoded.protocolVersion, 3);
      expect(decoded.action, FileTransferV3Action.ready);
      expect(decoded.transferId, 'transfer-1');
      expect(decoded.durableOffset, 16 * 1024 * 1024);
      expect(decoded.size, 64 * 1024 * 1024);
    });
  });

  group('FileTransferV3Parameters', () {
    test('uses 512KiB frames, 2MiB acks, and a 16MiB send window', () {
      expect(fileTransferV3FramePayloadSize, 512 * 1024);
      expect(fileTransferV3AckIntervalSize, 2 * 1024 * 1024);
      expect(fileTransferV3WindowSize, 16 * 1024 * 1024);
    });
  });
}
