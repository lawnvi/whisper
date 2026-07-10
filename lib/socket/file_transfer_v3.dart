import 'dart:convert';
import 'dart:math' as math;

const int fileTransferV3ProtocolVersion = 3;
const int fileTransferV3FramePayloadSize = 512 * 1024;
const int fileTransferV3AckIntervalSize = 2 * 1024 * 1024;
const int fileTransferV3WindowSize = 16 * 1024 * 1024;
const int fileTransferV3ResumeProofWindowSize = 1024 * 1024;
const int fileTransferV3MaxFileSize = 100 * 1024 * 1024 * 1024;
const String fileTransferV3ChecksumAlgorithm = 'sha256';

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

enum FileTransferV3Action {
  ready,
  ack,
  complete,
  cancel,
  error,
}

enum FileTransferFailureReason {
  none,
  invalidSize,
  invalidPath,
  invalidName,
  invalidMetadata,
  messageMissing,
  queueFull,
  storage,
  source,
  receiver,
  resumeProofMismatch,
  integrity,
  messageDeleted,
  deviceCleared,
  messageAssociationUnresolved,
  messageAssociationConflict,
  staleQueue,
  remoteFailure,
}

extension FileTransferFailureReasonWire on FileTransferFailureReason {
  String get wireCode => switch (this) {
        FileTransferFailureReason.none => '',
        FileTransferFailureReason.invalidSize => 'invalid_size',
        FileTransferFailureReason.invalidPath => 'invalid_path',
        FileTransferFailureReason.invalidName => 'invalid_name',
        FileTransferFailureReason.invalidMetadata => 'invalid_metadata',
        FileTransferFailureReason.messageMissing => 'message_missing',
        FileTransferFailureReason.queueFull => 'queue_full',
        FileTransferFailureReason.storage => 'storage',
        FileTransferFailureReason.source => 'source',
        FileTransferFailureReason.receiver => 'receiver',
        FileTransferFailureReason.resumeProofMismatch =>
          'resume_proof_mismatch',
        FileTransferFailureReason.integrity => 'integrity',
        FileTransferFailureReason.messageDeleted => 'message_deleted',
        FileTransferFailureReason.deviceCleared => 'device_cleared',
        FileTransferFailureReason.messageAssociationUnresolved =>
          'message_association_unresolved',
        FileTransferFailureReason.messageAssociationConflict =>
          'message_association_conflict',
        FileTransferFailureReason.staleQueue => 'stale_queue',
        FileTransferFailureReason.remoteFailure => 'remote_failure',
      };
}

const Set<String> fileTransferFailureWireCodes = <String>{
  '',
  'invalid_size',
  'invalid_path',
  'invalid_name',
  'invalid_metadata',
  'message_missing',
  'queue_full',
  'storage',
  'source',
  'receiver',
  'resume_proof_mismatch',
  'integrity',
  'message_deleted',
  'device_cleared',
  'message_association_unresolved',
  'message_association_conflict',
  'stale_queue',
  'remote_failure',
};

FileTransferFailureReason? fileTransferFailureReasonFromWire(String value) =>
    switch (value) {
      '' => FileTransferFailureReason.none,
      'invalid_size' => FileTransferFailureReason.invalidSize,
      'invalid_path' => FileTransferFailureReason.invalidPath,
      'invalid_name' => FileTransferFailureReason.invalidName,
      'invalid_metadata' => FileTransferFailureReason.invalidMetadata,
      'message_missing' => FileTransferFailureReason.messageMissing,
      'queue_full' => FileTransferFailureReason.queueFull,
      'storage' => FileTransferFailureReason.storage,
      'source' => FileTransferFailureReason.source,
      'receiver' => FileTransferFailureReason.receiver,
      'resume_proof_mismatch' => FileTransferFailureReason.resumeProofMismatch,
      'integrity' => FileTransferFailureReason.integrity,
      'message_deleted' => FileTransferFailureReason.messageDeleted,
      'device_cleared' => FileTransferFailureReason.deviceCleared,
      'message_association_unresolved' =>
        FileTransferFailureReason.messageAssociationUnresolved,
      'message_association_conflict' =>
        FileTransferFailureReason.messageAssociationConflict,
      'stale_queue' => FileTransferFailureReason.staleQueue,
      'remote_failure' => FileTransferFailureReason.remoteFailure,
      _ => null,
    };

class FileTransferV3Control {
  const FileTransferV3Control({
    required this.action,
    required this.transferId,
    required this.durableOffset,
    required this.size,
    required this.failureReason,
    this.resumeProofSha256 = '',
    this.resumeProofLength = 0,
    this.protocolVersion = fileTransferV3ProtocolVersion,
  });

  final int protocolVersion;
  final FileTransferV3Action action;
  final String transferId;
  final int durableOffset;
  final int size;
  final FileTransferFailureReason failureReason;
  final String resumeProofSha256;
  final int resumeProofLength;

  String get errorCode => failureReason.wireCode;
  String get errorMessage => failureReason.wireCode;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'protocolVersion': protocolVersion,
        'action': action.name,
        'transferId': transferId,
        'durableOffset': durableOffset,
        'size': size,
        'errorCode': failureReason.wireCode,
        'errorMessage': failureReason.wireCode,
        'resumeProofSha256': resumeProofSha256,
        'resumeProofLength': resumeProofLength,
      };

  factory FileTransferV3Control.fromJson(Map<String, dynamic> json) {
    final protocolVersion = json['protocolVersion'];
    final actionName = json['action'];
    final transferId = json['transferId'];
    final durableOffset = json['durableOffset'];
    final size = json['size'];
    final errorCode = json['errorCode'];
    final errorMessage = json['errorMessage'];
    final resumeProofSha256 = json['resumeProofSha256'];
    final resumeProofLength = json['resumeProofLength'];
    if (protocolVersion is! int ||
        actionName is! String ||
        transferId is! String ||
        durableOffset is! int ||
        size is! int ||
        errorCode is! String ||
        errorMessage is! String ||
        resumeProofSha256 is! String ||
        resumeProofLength is! int) {
      throw const FormatException('invalid file transfer control fields');
    }
    FileTransferV3Action action;
    try {
      action = FileTransferV3Action.values.byName(actionName);
    } on ArgumentError {
      throw const FormatException('unknown file transfer control action');
    }
    final failureReason = fileTransferFailureReasonFromWire(errorCode);
    if (failureReason == null ||
        (action == FileTransferV3Action.error &&
            failureReason == FileTransferFailureReason.none)) {
      throw const FormatException('unknown file transfer failure code');
    }
    final expectedProofLength = durableOffset <= 0
        ? 0
        : math.min(fileTransferV3ResumeProofWindowSize, durableOffset);
    final proofIsValid = action == FileTransferV3Action.ready
        ? resumeProofLength == expectedProofLength &&
            (expectedProofLength == 0
                ? resumeProofSha256.isEmpty
                : _sha256Hex.hasMatch(resumeProofSha256))
        : resumeProofLength == 0 && resumeProofSha256.isEmpty;
    if (durableOffset < 0 || size < 0 || !proofIsValid) {
      throw const FormatException('invalid file transfer resume proof');
    }
    return FileTransferV3Control(
      protocolVersion: protocolVersion,
      action: action,
      transferId: transferId,
      durableOffset: durableOffset,
      size: size,
      failureReason: failureReason,
      resumeProofSha256: resumeProofSha256,
      resumeProofLength: resumeProofLength,
    );
  }
}

final class FileTransferV3MetadataException extends FormatException {
  const FileTransferV3MetadataException(this.reason) : super(reason);

  final String reason;
}

final class FileTransferV3Metadata {
  const FileTransferV3Metadata({
    required this.checksumValue,
    this.protocolVersion = fileTransferV3ProtocolVersion,
    this.checksumAlgorithm = fileTransferV3ChecksumAlgorithm,
    this.chunkSize = fileTransferV3FramePayloadSize,
    this.windowSize = fileTransferV3WindowSize,
  });

  final int protocolVersion;
  final String checksumAlgorithm;
  final String checksumValue;
  final int chunkSize;
  final int windowSize;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'protocolVersion': protocolVersion,
        'checksumAlgorithm': checksumAlgorithm,
        'checksumValue': checksumValue,
        'chunkSize': chunkSize,
        'windowSize': windowSize,
      };

  static FileTransferV3Metadata parseOffer(
    String? content, {
    required int size,
  }) {
    if (size < 0 || size > fileTransferV3MaxFileSize) {
      throw const FileTransferV3MetadataException('invalid_size');
    }
    try {
      final decoded = jsonDecode(content ?? '');
      if (decoded is! Map<String, dynamic>) {
        throw const FileTransferV3MetadataException('invalid_metadata');
      }
      final protocolVersion = decoded['protocolVersion'];
      final checksumAlgorithm = decoded['checksumAlgorithm'];
      final checksumValue = decoded['checksumValue'];
      final chunkSize = decoded['chunkSize'];
      final windowSize = decoded['windowSize'];
      if (protocolVersion != fileTransferV3ProtocolVersion ||
          checksumAlgorithm != fileTransferV3ChecksumAlgorithm ||
          checksumValue is! String ||
          !_sha256Hex.hasMatch(checksumValue) ||
          chunkSize != fileTransferV3FramePayloadSize ||
          windowSize != fileTransferV3WindowSize) {
        throw const FileTransferV3MetadataException('invalid_metadata');
      }
      return FileTransferV3Metadata(checksumValue: checksumValue);
    } on FileTransferV3MetadataException {
      rethrow;
    } catch (_) {
      throw const FileTransferV3MetadataException('invalid_metadata');
    }
  }
}
