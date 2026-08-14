import 'dart:convert';

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
        failureReason: FileTransferFailureReason.none,
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
      expect(decoded.hasFlowParameters, isFalse);
    });

    test('round-trips negotiated flow parameters on ready', () {
      const ready = FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: 'transfer-1',
        durableOffset: 0,
        size: 64 * 1024 * 1024,
        failureReason: FileTransferFailureReason.none,
        chunkSize: fileTransferV3FramePayloadSize,
        ackIntervalSize: fileTransferV3AckIntervalSize,
        windowSize: fileTransferV3WindowSize,
      );

      final decoded = FileTransferV3Control.fromJson(ready.toJson());

      expect(decoded.hasFlowParameters, isTrue);
      expect(decoded.chunkSize, fileTransferV3FramePayloadSize);
      expect(decoded.ackIntervalSize, fileTransferV3AckIntervalSize);
      expect(decoded.windowSize, fileTransferV3WindowSize);
    });

    test('rejects partial, invalid, or misplaced flow parameters', () {
      const ready = FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: 'transfer-1',
        durableOffset: 0,
        size: 64 * 1024 * 1024,
        failureReason: FileTransferFailureReason.none,
      );
      final valid = ready.toJson();

      for (final invalid in <Map<String, dynamic>>[
        <String, dynamic>{
          ...valid,
          'chunkSize': fileTransferV3FramePayloadSize,
        },
        <String, dynamic>{
          ...valid,
          'chunkSize': fileTransferV3FramePayloadSize,
          'ackIntervalSize': fileTransferV3AckIntervalSize,
          'windowSize': fileTransferV3WindowSize - 1,
        },
        <String, dynamic>{
          ...valid,
          'action': 'ack',
          'chunkSize': fileTransferV3FramePayloadSize,
          'ackIntervalSize': fileTransferV3AckIntervalSize,
          'windowSize': fileTransferV3WindowSize,
        },
      ]) {
        expect(
          () => FileTransferV3Control.fromJson(invalid),
          throwsFormatException,
        );
      }
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
        () => FileTransferV3Control.fromJson(<String, Object?>{
          ...valid,
          'action': 'surprise',
        }),
        throwsFormatException,
      );
      expect(
        () => FileTransferV3Control.fromJson(<String, Object?>{
          ...valid,
          'durableOffset': '0',
        }),
        throwsFormatException,
      );
    });

    test('validates ready proof shape against the durable offset', () {
      Map<String, Object?> ready({
        required int offset,
        required String proof,
        required int proofLength,
      }) => <String, Object?>{
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

    test('verify requires a final SHA-256 checksum', () {
      final verify = FileTransferV3Control(
        action: FileTransferV3Action.verify,
        transferId: 'transfer-1',
        durableOffset: 4,
        size: 4,
        failureReason: FileTransferFailureReason.none,
        checksumValue:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );

      expect(
        FileTransferV3Control.fromJson(verify.toJson()).checksumValue,
        verify.checksumValue,
      );
      expect(
        () => FileTransferV3Control.fromJson(<String, dynamic>{
          ...verify.toJson(),
          'checksumValue': '',
        }),
        throwsFormatException,
      );
    });

    test('accepts only closed failure codes and discards remote detail', () {
      const secret = 'token=never-log-this /Users/alice/Documents/private.txt';
      final valid = <String, Object?>{
        'protocolVersion': 3,
        'action': 'error',
        'transferId': 'transfer-1',
        'durableOffset': 0,
        'size': 1,
        'errorCode': 'source',
        'errorMessage': secret,
        'resumeProofSha256': '',
        'resumeProofLength': 0,
      };

      final decoded = FileTransferV3Control.fromJson(valid);

      expect(decoded.failureReason, FileTransferFailureReason.source);
      expect(decoded.errorCode, 'source');
      expect(decoded.errorMessage, 'source');
      expect(jsonEncode(decoded.toJson()), isNot(contains(secret)));
      expect(
        () => FileTransferV3Control.fromJson(<String, Object?>{
          ...valid,
          'errorCode': 'remote says $secret',
        }),
        throwsFormatException,
      );
    });
  });

  group('FileTransferV3Parameters', () {
    test('uses 4MiB frames, 32MiB acks, and a 64MiB send window', () {
      expect(fileTransferV3FramePayloadSize, 4 * 1024 * 1024);
      expect(fileTransferV3AckIntervalSize, 32 * 1024 * 1024);
      expect(fileTransferV3WindowSize, 64 * 1024 * 1024);
      expect(
        fileTransferV3AckIntervalSize,
        lessThanOrEqualTo(fileTransferV3WindowSize),
      );
    });

    test('negotiates desktop, mobile, and legacy transfer rhythms', () {
      const modernOffer = FileTransferV3Metadata(
        checksumValue:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        maxChunkSize: fileTransferV3FramePayloadSize,
        maxWindowSize: fileTransferV3WindowSize,
      );

      final desktop = selectFileTransferV3FlowParameters(
        offer: modernOffer,
        localLimits: FileTransferV3FlowParameters.desktop,
      );
      expect(desktop.chunkSize, fileTransferV3FramePayloadSize);
      expect(desktop.ackIntervalSize, fileTransferV3AckIntervalSize);
      expect(desktop.windowSize, fileTransferV3WindowSize);
      expect(desktop.negotiated, isTrue);

      final mobile = selectFileTransferV3FlowParameters(
        offer: modernOffer,
        localLimits: FileTransferV3FlowParameters.mobile,
      );
      expect(mobile.chunkSize, fileTransferV3MobileFramePayloadSize);
      expect(mobile.ackIntervalSize, fileTransferV3MobileAckIntervalSize);
      expect(mobile.windowSize, fileTransferV3MobileWindowSize);
      expect(mobile.negotiated, isTrue);

      const legacyOffer = FileTransferV3Metadata(
        checksumValue:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      final legacy = selectFileTransferV3FlowParameters(
        offer: legacyOffer,
        localLimits: FileTransferV3FlowParameters.desktop,
      );
      expect(legacy.chunkSize, fileTransferV3LegacyFramePayloadSize);
      expect(legacy.ackIntervalSize, fileTransferV3LegacyAckIntervalSize);
      expect(legacy.windowSize, fileTransferV3LegacyWindowSize);
      expect(legacy.negotiated, isFalse);
    });
  });
}
