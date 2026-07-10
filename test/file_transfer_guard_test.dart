import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/file.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_input_policy.dart';

const _transferId = '01234567-89ab-4cde-8fab-0123456789ab';

FileTransferData _incomingTransfer({
  String peerUid = 'peer-a',
  int committedBytes = 4,
  int size = 12,
}) {
  return FileTransferData(
    transferId: _transferId,
    messageUuid: _transferId,
    messageRowId: 0,
    peerUid: peerUid,
    direction: FileTransferDirection.incoming,
    state: FileTransferState.transferring,
    finalPath: '/tmp/final.bin',
    tempPath: '/tmp/part.bin',
    size: size,
    checksumAlgorithm: 'sha256',
    checksumValue:
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    chunkSize: fileTransferV3FramePayloadSize,
    committedBytes: committedBytes,
    resumeProofResetCount: 0,
    lastError: '',
    createdAt: 1,
    updatedAt: 1,
  );
}

WhisperFrameV3 _dataFrame({
  int offset = 4,
  int sequence = 2,
  int flags = 0,
  int payloadLength = 4,
}) {
  return WhisperFrameV3(
    type: WhisperFrameType.fileData,
    transferId: _transferId,
    offset: offset,
    sequence: sequence,
    flags: flags,
    payload: Uint8List(payloadLength),
  );
}

MessageData _fileOfferMessage({
  MessageEnum type = MessageEnum.File,
  String uuid = _transferId,
  int size = 12,
}) {
  return MessageData(
    id: 0,
    sender: 'peer-a',
    receiver: 'local',
    name: 'payload.bin',
    clipboard: false,
    size: size,
    type: type,
    content: jsonEncode(
      const FileTransferV3Metadata(
        checksumValue:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      ).toJson(),
    ),
    message: '',
    timestamp: 1,
    uuid: uuid,
    acked: false,
    path: '',
    md5: '',
  );
}

void main() {
  group('hasEnoughStorageForFile', () {
    test(
        'returns false when available bytes are lower than file size and reserve',
        () {
      expect(
        hasEnoughStorageForFile(
          fileSize: 100,
          availableBytes: 120,
          reserveBytes: 32,
        ),
        isFalse,
      );
    });

    test('returns true when available bytes cover file size and reserve', () {
      expect(
        hasEnoughStorageForFile(
          fileSize: 100,
          availableBytes: 160,
          reserveBytes: 32,
        ),
        isTrue,
      );
    });

    test('returns true when available bytes cannot be determined', () {
      expect(
        hasEnoughStorageForFile(
          fileSize: 100,
          availableBytes: null,
        ),
        isTrue,
      );
    });
  });

  group('isFileIntegrityValid', () {
    test('returns true when checksum matches', () {
      expect(
        isFileIntegrityValid(
          expectedMd5: 'abc123',
          actualMd5: 'abc123',
        ),
        isTrue,
      );
    });

    test('returns false when checksum does not match', () {
      expect(
        isFileIntegrityValid(
          expectedMd5: 'abc123',
          actualMd5: 'xyz456',
        ),
        isFalse,
      );
    });

    test('returns true when expected checksum is empty', () {
      expect(
        isFileIntegrityValid(
          expectedMd5: '',
          actualMd5: 'xyz456',
        ),
        isTrue,
      );
    });
  });

  group('transfer checksum helpers', () {
    test('uses sha256 for resumable transfer checksum', () async {
      final directory = await Directory.systemTemp.createTemp('whisper-test-');
      final file = File('${directory.path}/payload.bin');
      await file.writeAsBytes(const <int>[1, 2, 3, 4]);

      final digest = await fileChecksum(file, algorithm: 'sha256');

      expect(
        digest,
        '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
      );
      await directory.delete(recursive: true);
    });

    test('computes resume proof hash from the previous full chunk', () async {
      final directory = await Directory.systemTemp.createTemp('whisper-test-');
      final file = File('${directory.path}/payload.bin');
      await file.writeAsBytes(List<int>.generate(8, (index) => index + 1));

      final proof = await resumeProofHash(
        file,
        resumeOffset: 8,
        chunkSize: 4,
      );

      expect(
        proof,
        '55e5509f8052998294266ee5b50cb592938191fb5d67f73cac2e60b0276b1bdd',
      );
      await directory.delete(recursive: true);
    });
  });

  group('authenticated file data guard', () {
    test('accepts the next bounded frame for the active peer transfer', () {
      final result = WireInputPolicy.validateFileData(
        frame: _dataFrame(),
        transfer: _incomingTransfer(),
        authenticatedPeerId: 'peer-a',
        expectedOffset: 4,
        expectedSequence: 2,
        isActive: true,
      );

      expect(result.isAccepted, isTrue);
    });

    test('classifies a fully committed retransmission as duplicate', () {
      final result = WireInputPolicy.validateFileData(
        frame: _dataFrame(offset: 4, sequence: 2, payloadLength: 4),
        transfer: _incomingTransfer(committedBytes: 8),
        authenticatedPeerId: 'peer-a',
        expectedOffset: 8,
        expectedSequence: 2,
        isActive: true,
      );

      expect(result.disposition, FileDataDisposition.duplicate);
      expect(result.isDuplicate, isTrue);
    });

    test('duplicate classification still rejects sequence, overlap, and gap',
        () {
      FileDataValidationResult validate(WhisperFrameV3 frame) =>
          WireInputPolicy.validateFileData(
            frame: frame,
            transfer: _incomingTransfer(committedBytes: 8, size: 16),
            authenticatedPeerId: 'peer-a',
            expectedOffset: 8,
            expectedSequence: 2,
            isActive: true,
          );

      expect(
        validate(_dataFrame(offset: 4, sequence: 1)).reason,
        WireInputReason.transferSequenceInvalid,
      );
      expect(
        validate(_dataFrame(offset: 6, sequence: 2)).reason,
        WireInputReason.transferOffsetInvalid,
      );
      expect(
        validate(_dataFrame(offset: 9, sequence: 2)).reason,
        WireInputReason.transferOffsetInvalid,
      );
    });

    test('rejects peer, direction, and inactive transfer before writing', () {
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(),
          transfer: _incomingTransfer(),
          authenticatedPeerId: 'peer-b',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: true,
        ).reason,
        WireInputReason.transferPeerMismatch,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(),
          transfer: _incomingTransfer().copyWith(
            direction: FileTransferDirection.outgoing,
          ),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: true,
        ).reason,
        WireInputReason.transferDirectionMismatch,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(),
          transfer: _incomingTransfer(),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: false,
        ).reason,
        WireInputReason.transferInactive,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(),
          transfer: _incomingTransfer().copyWith(
            state: FileTransferState.canceled,
          ),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: false,
        ).isIgnored,
        isTrue,
      );
    });

    test('rejects oversized, empty, or declared-size-overflow payloads', () {
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(payloadLength: fileTransferV3FramePayloadSize + 1),
          transfer: _incomingTransfer(size: fileTransferV3FramePayloadSize + 8),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: true,
        ).reason,
        WireInputReason.transferPayloadInvalid,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(payloadLength: 0),
          transfer: _incomingTransfer(),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: true,
        ).reason,
        WireInputReason.transferPayloadInvalid,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(offset: 10, payloadLength: 4),
          transfer: _incomingTransfer(size: 12),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 10,
          expectedSequence: 2,
          isActive: true,
        ).reason,
        WireInputReason.transferSizeInvalid,
      );
    });

    test('terminal transfers still reject malformed frame headers and bounds',
        () {
      final terminal = _incomingTransfer().copyWith(
        state: FileTransferState.canceled,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(flags: 1),
          transfer: terminal,
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: false,
        ).reason,
        WireInputReason.transferFlagsInvalid,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(payloadLength: 0),
          transfer: terminal,
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: false,
        ).reason,
        WireInputReason.transferPayloadInvalid,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(offset: 10, payloadLength: 4),
          transfer: terminal,
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: false,
        ).reason,
        WireInputReason.transferSizeInvalid,
      );
    });

    test('rejects negative/non-contiguous offset and invalid sequence/flags',
        () {
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(offset: -1),
          transfer: _incomingTransfer(),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: true,
        ).reason,
        WireInputReason.transferOffsetInvalid,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(offset: 5),
          transfer: _incomingTransfer(),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: true,
        ).reason,
        WireInputReason.transferOffsetInvalid,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(sequence: 3),
          transfer: _incomingTransfer(),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: true,
        ).reason,
        WireInputReason.transferSequenceInvalid,
      );
      expect(
        WireInputPolicy.validateFileData(
          frame: _dataFrame(flags: 1),
          transfer: _incomingTransfer(),
          authenticatedPeerId: 'peer-a',
          expectedOffset: 4,
          expectedSequence: 2,
          isActive: true,
        ).reason,
        WireInputReason.transferFlagsInvalid,
      );
    });
  });

  group('authenticated file offer guard', () {
    test('requires a bound File message and matching zeroed header', () {
      WhisperFrameV3 frame({
        String transferId = _transferId,
        int offset = 0,
        int sequence = 0,
        int flags = 0,
      }) {
        return WhisperFrameV3(
          type: WhisperFrameType.fileOffer,
          transferId: transferId,
          offset: offset,
          sequence: sequence,
          flags: flags,
          payload: Uint8List(1),
        );
      }

      expect(
        WireInputPolicy.validateFileOffer(
          frame: frame(),
          message: _fileOfferMessage(),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).isAccepted,
        isTrue,
      );
      expect(
        WireInputPolicy.validateFileOffer(
          frame: frame(offset: 1),
          message: _fileOfferMessage(),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.transferOffsetInvalid,
      );
      expect(
        WireInputPolicy.validateFileOffer(
          frame: frame(sequence: 1),
          message: _fileOfferMessage(),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.transferSequenceInvalid,
      );
      expect(
        WireInputPolicy.validateFileOffer(
          frame: frame(flags: 1),
          message: _fileOfferMessage(),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.transferFlagsInvalid,
      );
      expect(
        WireInputPolicy.validateFileOffer(
          frame: frame(
            transferId: '11234567-89ab-4cde-8fab-0123456789ab',
          ),
          message: _fileOfferMessage(),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.transferFrameMismatch,
      );
      expect(
        WireInputPolicy.validateFileOffer(
          frame: frame(),
          message: _fileOfferMessage(type: MessageEnum.Text),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.transferFrameMismatch,
      );
      expect(
        WireInputPolicy.validateFileOffer(
          frame: frame(),
          message: _fileOfferMessage(size: -1),
          authenticatedPeerId: 'peer-a',
          localPeerId: 'local',
        ).reason,
        WireInputReason.transferSizeInvalid,
      );
    });
  });

  group('authenticated file control guard', () {
    test('requires frame type, action, id, offset, size, and peer to agree',
        () {
      final transfer = _incomingTransfer().copyWith(
        direction: FileTransferDirection.outgoing,
      );
      const control = FileTransferV3Control(
        action: FileTransferV3Action.ack,
        transferId: _transferId,
        durableOffset: 4,
        size: 12,
        errorCode: '',
        errorMessage: '',
      );
      WhisperFrameV3 frame({
        WhisperFrameType type = WhisperFrameType.fileAck,
        String transferId = _transferId,
        int offset = 4,
        int sequence = 0,
        int flags = 0,
      }) {
        return WhisperFrameV3(
          type: type,
          transferId: transferId,
          offset: offset,
          sequence: sequence,
          flags: flags,
          payload: Uint8List(1),
        );
      }

      expect(
        WireInputPolicy.validateFileControl(
          frame: frame(),
          control: control,
          transfer: transfer,
          authenticatedPeerId: 'peer-a',
        ).isAccepted,
        isTrue,
      );
      for (final invalid in <({WhisperFrameV3 frame, String reason})>[
        (
          frame: frame(type: WhisperFrameType.fileReady),
          reason: WireInputReason.transferFrameMismatch,
        ),
        (
          frame: frame(
            transferId: '11234567-89ab-4cde-8fab-0123456789ab',
          ),
          reason: WireInputReason.transferFrameMismatch,
        ),
        (
          frame: frame(offset: 5),
          reason: WireInputReason.transferOffsetInvalid,
        ),
        (
          frame: frame(sequence: 1),
          reason: WireInputReason.transferSequenceInvalid,
        ),
        (
          frame: frame(flags: 1),
          reason: WireInputReason.transferFlagsInvalid,
        ),
      ]) {
        expect(
          WireInputPolicy.validateFileControl(
            frame: invalid.frame,
            control: control,
            transfer: transfer,
            authenticatedPeerId: 'peer-a',
          ).reason,
          invalid.reason,
        );
      }
      expect(
        WireInputPolicy.validateFileControl(
          frame: frame(),
          control: control,
          transfer: transfer,
          authenticatedPeerId: 'peer-b',
        ).reason,
        WireInputReason.transferPeerMismatch,
      );
      expect(
        WireInputPolicy.validateFileControl(
          frame: frame(),
          control: const FileTransferV3Control(
            action: FileTransferV3Action.ack,
            transferId: _transferId,
            durableOffset: 4,
            size: 13,
            errorCode: '',
            errorMessage: '',
          ),
          transfer: transfer,
          authenticatedPeerId: 'peer-a',
        ).reason,
        WireInputReason.transferSizeInvalid,
      );
      expect(
        WireInputPolicy.validateFileControl(
          frame: frame(),
          control: control,
          transfer: transfer.copyWith(state: FileTransferState.completed),
          authenticatedPeerId: 'peer-a',
        ).isIgnored,
        isTrue,
      );
      final incompleteComplete = FileTransferV3Control(
        action: FileTransferV3Action.complete,
        transferId: _transferId,
        durableOffset: 4,
        size: 12,
        errorCode: '',
        errorMessage: '',
      );
      expect(
        WireInputPolicy.validateFileControl(
          frame: frame(type: WhisperFrameType.fileComplete),
          control: incompleteComplete,
          transfer: transfer,
          authenticatedPeerId: 'peer-a',
        ).reason,
        WireInputReason.transferOffsetInvalid,
      );
    });

    test('terminal transfers still reject malformed control bounds', () {
      final transfer = _incomingTransfer().copyWith(
        direction: FileTransferDirection.outgoing,
        state: FileTransferState.completed,
      );
      const wrongSize = FileTransferV3Control(
        action: FileTransferV3Action.ack,
        transferId: _transferId,
        durableOffset: 4,
        size: 13,
        errorCode: '',
        errorMessage: '',
      );
      final wrongSizeFrame = WhisperFrameV3(
        type: WhisperFrameType.fileAck,
        transferId: _transferId,
        offset: 4,
        sequence: 0,
        payload: Uint8List(1),
      );
      expect(
        WireInputPolicy.validateFileControl(
          frame: wrongSizeFrame,
          control: wrongSize,
          transfer: transfer,
          authenticatedPeerId: 'peer-a',
        ).reason,
        WireInputReason.transferSizeInvalid,
      );

      const oversizedOffset = FileTransferV3Control(
        action: FileTransferV3Action.ack,
        transferId: _transferId,
        durableOffset: 13,
        size: 12,
        errorCode: '',
        errorMessage: '',
      );
      final oversizedOffsetFrame = WhisperFrameV3(
        type: WhisperFrameType.fileAck,
        transferId: _transferId,
        offset: 13,
        sequence: 0,
        payload: Uint8List(1),
      );
      expect(
        WireInputPolicy.validateFileControl(
          frame: oversizedOffsetFrame,
          control: oversizedOffset,
          transfer: transfer,
          authenticatedPeerId: 'peer-a',
        ).reason,
        WireInputReason.transferOffsetInvalid,
      );
    });
  });
}
