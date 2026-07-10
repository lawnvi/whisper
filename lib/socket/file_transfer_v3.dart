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

class FileTransferV3Control {
  const FileTransferV3Control({
    required this.action,
    required this.transferId,
    required this.durableOffset,
    required this.size,
    required this.errorCode,
    required this.errorMessage,
    this.resumeProofSha256 = '',
    this.resumeProofLength = 0,
    this.protocolVersion = fileTransferV3ProtocolVersion,
  });

  final int protocolVersion;
  final FileTransferV3Action action;
  final String transferId;
  final int durableOffset;
  final int size;
  final String errorCode;
  final String errorMessage;
  final String resumeProofSha256;
  final int resumeProofLength;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'protocolVersion': protocolVersion,
        'action': action.name,
        'transferId': transferId,
        'durableOffset': durableOffset,
        'size': size,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
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
      errorCode: errorCode,
      errorMessage: errorMessage,
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
