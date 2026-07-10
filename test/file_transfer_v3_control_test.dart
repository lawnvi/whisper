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
        resumeProofSha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        resumeProofLength: fileTransferV3ResumeProofWindowSize,
      );

      final decoded = FileTransferV3Control.fromJson(ready.toJson());

      expect(decoded.protocolVersion, 3);
      expect(decoded.action, FileTransferV3Action.ready);
      expect(decoded.transferId, 'transfer-1');
      expect(decoded.durableOffset, 16 * 1024 * 1024);
      expect(decoded.size, 64 * 1024 * 1024);
      expect(decoded.resumeProofLength, fileTransferV3ResumeProofWindowSize);
      expect(decoded.resumeProofSha256, ready.resumeProofSha256);
    });

    test('rejects unknown actions and malformed numeric fields', () {
      final valid = <String, Object?>{
        'protocolVersion': 3,
        'action': 'ack',
        'transferId': 'transfer-1',
        'durableOffset': 0,
        'size': 1,
        'errorCode': '',
        'errorMessage': '',
        'resumeProofSha256': '',
        'resumeProofLength': 0,
      };

      expect(
        () => FileTransferV3Control.fromJson(
          <String, Object?>{...valid, 'action': 'surprise'},
        ),
        throwsFormatException,
      );
      expect(
        () => FileTransferV3Control.fromJson(
          <String, Object?>{...valid, 'durableOffset': '0'},
        ),
        throwsFormatException,
      );
    });

    test('validates ready proof shape against the durable offset', () {
      Map<String, Object?> ready({
        required int offset,
        required String proof,
        required int proofLength,
      }) =>
          <String, Object?>{
            'protocolVersion': 3,
            'action': 'ready',
            'transferId': 'transfer-1',
            'durableOffset': offset,
            'size': 2 * 1024 * 1024,
            'errorCode': '',
            'errorMessage': '',
            'resumeProofSha256': proof,
            'resumeProofLength': proofLength,
          };

      expect(
        FileTransferV3Control.fromJson(
          ready(offset: 0, proof: '', proofLength: 0),
        ).resumeProofLength,
        0,
      );
      expect(
        FileTransferV3Control.fromJson(
          ready(
            offset: 128,
            proof:
                '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
            proofLength: 128,
          ),
        ).resumeProofLength,
        128,
      );
      for (final invalid in <Map<String, Object?>>[
        ready(offset: 0, proof: '0' * 64, proofLength: 0),
        ready(offset: 128, proof: '', proofLength: 0),
        ready(offset: 128, proof: '0' * 64, proofLength: 127),
        ready(offset: 128, proof: 'A' * 64, proofLength: 128),
      ]) {
        expect(
          () => FileTransferV3Control.fromJson(invalid),
          throwsFormatException,
        );
      }
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
