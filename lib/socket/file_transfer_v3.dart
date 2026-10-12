import 'dart:convert';
import 'dart:math' as math;

import 'package:whisper/socket/folder_transfer_manifest.dart';

const int fileTransferV3ProtocolVersion = 3;
const int fileTransferV3LegacyFramePayloadSize = 512 * 1024;
const int fileTransferV3LegacyAckIntervalSize = 2 * 1024 * 1024;
const int fileTransferV3LegacyWindowSize = 4 * 1024 * 1024;
const int fileTransferV3FramePayloadSize = 4 * 1024 * 1024;
const int fileTransferV3AckIntervalSize = 32 * 1024 * 1024;
const int fileTransferV3WindowSize = 64 * 1024 * 1024;
const int fileTransferV3MaxOfferWindowSize = 64 * 1024 * 1024;
const int fileTransferV3MobileFramePayloadSize = 1024 * 1024;
const int fileTransferV3MobileAckIntervalSize = 8 * 1024 * 1024;
const int fileTransferV3MobileWindowSize = 16 * 1024 * 1024;
const int fileTransferV3ResumeProofWindowSize = 1024 * 1024;
const int fileTransferV3MaxFileSize = 100 * 1024 * 1024 * 1024;
const String fileTransferV3ChecksumAlgorithm = 'sha256';

/// Marks an offer as a folder stream: the offer's checksum is the SHA-256 of
/// the manifest, and each file is verified by the trailer that follows it.
/// A peer that predates folder transfer does not know this name and turns
/// the offer down as invalid metadata instead of saving the stream as a file.
const String fileTransferFolderChecksumAlgorithm = 'sha256-folder-v1';

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

final class FileTransferV3FlowParameters {
  const FileTransferV3FlowParameters({
    required this.chunkSize,
    required this.ackIntervalSize,
    required this.windowSize,
    this.negotiated = false,
  });

  static const legacy = FileTransferV3FlowParameters(
    chunkSize: fileTransferV3LegacyFramePayloadSize,
    ackIntervalSize: fileTransferV3LegacyAckIntervalSize,
    windowSize: fileTransferV3LegacyWindowSize,
  );

  static const desktop = FileTransferV3FlowParameters(
    chunkSize: fileTransferV3FramePayloadSize,
    ackIntervalSize: fileTransferV3AckIntervalSize,
    windowSize: fileTransferV3WindowSize,
  );

  static const mobile = FileTransferV3FlowParameters(
    chunkSize: fileTransferV3MobileFramePayloadSize,
    ackIntervalSize: fileTransferV3MobileAckIntervalSize,
    windowSize: fileTransferV3MobileWindowSize,
  );

  final int chunkSize;
  final int ackIntervalSize;
  final int windowSize;
  final bool negotiated;
}

bool isValidFileTransferV3FlowParameters({
  required int chunkSize,
  required int ackIntervalSize,
  required int windowSize,
}) {
  return chunkSize >= fileTransferV3LegacyFramePayloadSize &&
      chunkSize <= fileTransferV3FramePayloadSize &&
      chunkSize % fileTransferV3LegacyFramePayloadSize == 0 &&
      windowSize >= chunkSize &&
      windowSize <= fileTransferV3MaxOfferWindowSize &&
      windowSize % chunkSize == 0 &&
      ackIntervalSize >= chunkSize &&
      ackIntervalSize <= windowSize &&
      ackIntervalSize % chunkSize == 0;
}

enum FileTransferV3Action { ready, ack, verify, complete, cancel, error }

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
  folderUnsupported,
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
    FileTransferFailureReason.resumeProofMismatch => 'resume_proof_mismatch',
    FileTransferFailureReason.integrity => 'integrity',
    FileTransferFailureReason.messageDeleted => 'message_deleted',
    FileTransferFailureReason.deviceCleared => 'device_cleared',
    FileTransferFailureReason.messageAssociationUnresolved =>
      'message_association_unresolved',
    FileTransferFailureReason.messageAssociationConflict =>
      'message_association_conflict',
    FileTransferFailureReason.staleQueue => 'stale_queue',
    FileTransferFailureReason.remoteFailure => 'remote_failure',
    FileTransferFailureReason.folderUnsupported => 'folder_unsupported',
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
  'folder_unsupported',
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
      'folder_unsupported' => FileTransferFailureReason.folderUnsupported,
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
    this.checksumValue = '',
    this.chunkSize = 0,
    this.ackIntervalSize = 0,
    this.windowSize = 0,
    this.skippedEntries = 0,
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
  final String checksumValue;
  final int chunkSize;
  final int ackIntervalSize;
  final int windowSize;

  /// With `complete` for a folder: how many of its files the receiver did
  /// not end up with.
  final int skippedEntries;

  bool get hasFlowParameters => chunkSize > 0;

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
    'checksumValue': checksumValue,
    if (hasFlowParameters) ...<String, int>{
      'chunkSize': chunkSize,
      'ackIntervalSize': ackIntervalSize,
      'windowSize': windowSize,
    },
    if (skippedEntries > 0) 'skippedEntries': skippedEntries,
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
    final checksumValue = json['checksumValue'] ?? '';
    final chunkSize = json['chunkSize'] ?? 0;
    final ackIntervalSize = json['ackIntervalSize'] ?? 0;
    final windowSize = json['windowSize'] ?? 0;
    final skippedEntries = json['skippedEntries'] ?? 0;
    if (protocolVersion is! int ||
        actionName is! String ||
        transferId is! String ||
        durableOffset is! int ||
        size is! int ||
        errorCode is! String ||
        errorMessage is! String ||
        resumeProofSha256 is! String ||
        resumeProofLength is! int ||
        checksumValue is! String ||
        chunkSize is! int ||
        ackIntervalSize is! int ||
        windowSize is! int ||
        skippedEntries is! int) {
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
    final checksumIsValid = action == FileTransferV3Action.verify
        ? _sha256Hex.hasMatch(checksumValue)
        : checksumValue.isEmpty;
    final hasAnyFlowParameter =
        chunkSize != 0 || ackIntervalSize != 0 || windowSize != 0;
    final flowIsValid =
        !hasAnyFlowParameter ||
        (action == FileTransferV3Action.ready &&
            isValidFileTransferV3FlowParameters(
              chunkSize: chunkSize,
              ackIntervalSize: ackIntervalSize,
              windowSize: windowSize,
            ));
    if (durableOffset < 0 ||
        size < 0 ||
        !proofIsValid ||
        !checksumIsValid ||
        !flowIsValid ||
        skippedEntries < 0 ||
        skippedEntries > folderManifestMaxEntries ||
        (skippedEntries != 0 && action != FileTransferV3Action.complete) ||
        (action == FileTransferV3Action.verify && durableOffset != size)) {
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
      checksumValue: checksumValue,
      chunkSize: chunkSize,
      ackIntervalSize: ackIntervalSize,
      windowSize: windowSize,
      skippedEntries: skippedEntries,
    );
  }
}

/// What a folder offer says about the folder before any of it has arrived.
final class FolderOfferSummary {
  const FolderOfferSummary({
    required this.manifestLength,
    required this.fileCount,
    required this.directoryCount,
    required this.totalBytes,
    this.skippedAtSource = 0,
  });

  final int manifestLength;
  final int fileCount;
  final int directoryCount;

  /// The files' own bytes, without manifest and trailers.
  final int totalBytes;

  /// Entries the sender left out while scanning: links, special files and
  /// names other platforms cannot hold.
  final int skippedAtSource;

  int get streamSize =>
      manifestLength + totalBytes + fileCount * folderTrailerLength;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'manifestLength': manifestLength,
    'fileCount': fileCount,
    'directoryCount': directoryCount,
    'totalBytes': totalBytes,
    'skippedAtSource': skippedAtSource,
  };

  static FolderOfferSummary? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final manifestLength = json['manifestLength'];
    final fileCount = json['fileCount'];
    final directoryCount = json['directoryCount'];
    final totalBytes = json['totalBytes'];
    final skippedAtSource = json['skippedAtSource'] ?? 0;
    if (manifestLength is! int ||
        fileCount is! int ||
        directoryCount is! int ||
        totalBytes is! int ||
        skippedAtSource is! int ||
        manifestLength < folderManifestHeaderLength ||
        manifestLength > folderManifestMaxBytes ||
        fileCount < 0 ||
        directoryCount < 0 ||
        fileCount + directoryCount > folderManifestMaxEntries ||
        totalBytes < 0 ||
        totalBytes > folderStreamMaxSize ||
        skippedAtSource < 0) {
      return null;
    }
    return FolderOfferSummary(
      manifestLength: manifestLength,
      fileCount: fileCount,
      directoryCount: directoryCount,
      totalBytes: totalBytes,
      skippedAtSource: skippedAtSource,
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
    this.checksumDeferred = false,
    this.protocolVersion = fileTransferV3ProtocolVersion,
    this.checksumAlgorithm = fileTransferV3ChecksumAlgorithm,
    this.chunkSize = fileTransferV3LegacyFramePayloadSize,
    this.windowSize = fileTransferV3LegacyWindowSize,
    this.maxChunkSize,
    this.maxWindowSize,
    this.folder,
  });

  final int protocolVersion;
  final String checksumAlgorithm;
  final String checksumValue;
  final bool checksumDeferred;
  final int chunkSize;
  final int windowSize;
  final int? maxChunkSize;
  final int? maxWindowSize;

  /// Set when the transfer is a folder stream rather than one file.
  final FolderOfferSummary? folder;

  bool get isFolder => folder != null;

  bool get supportsFlowNegotiation =>
      maxChunkSize != null && maxWindowSize != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'protocolVersion': protocolVersion,
    'checksumAlgorithm': checksumAlgorithm,
    'checksumValue': checksumValue,
    'checksumDeferred': checksumDeferred,
    'chunkSize': chunkSize,
    'windowSize': windowSize,
    if (supportsFlowNegotiation) ...<String, int>{
      'maxChunkSize': maxChunkSize!,
      'maxWindowSize': maxWindowSize!,
    },
    if (folder != null) 'folder': folder!.toJson(),
  };

  static FileTransferV3Metadata parseOffer(
    String? content, {
    required int size,
  }) {
    if (size < 0 || size > folderStreamMaxSize) {
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
      final checksumDeferred = decoded['checksumDeferred'] ?? false;
      final chunkSize = decoded['chunkSize'];
      final windowSize = decoded['windowSize'];
      final hasMaxChunkSize = decoded.containsKey('maxChunkSize');
      final hasMaxWindowSize = decoded.containsKey('maxWindowSize');
      final maxChunkSize = decoded['maxChunkSize'];
      final maxWindowSize = decoded['maxWindowSize'];
      final hasCompleteFlowExtension = hasMaxChunkSize && hasMaxWindowSize;
      final isFolder = checksumAlgorithm == fileTransferFolderChecksumAlgorithm;
      final folder = isFolder
          ? FolderOfferSummary.tryParse(decoded['folder'])
          : null;
      if (!isFolder && size > fileTransferV3MaxFileSize) {
        throw const FileTransferV3MetadataException('invalid_size');
      }
      if (isFolder &&
          (folder == null ||
              folder.streamSize != size ||
              checksumDeferred != false)) {
        throw const FileTransferV3MetadataException('invalid_metadata');
      }
      if (protocolVersion != fileTransferV3ProtocolVersion ||
          (!isFolder && checksumAlgorithm != fileTransferV3ChecksumAlgorithm) ||
          checksumValue is! String ||
          checksumDeferred is! bool ||
          (checksumDeferred
              ? checksumValue.isNotEmpty
              : !_sha256Hex.hasMatch(checksumValue)) ||
          chunkSize is! int ||
          windowSize is! int ||
          windowSize < fileTransferV3LegacyFramePayloadSize ||
          windowSize > fileTransferV3MaxOfferWindowSize ||
          windowSize % fileTransferV3LegacyFramePayloadSize != 0 ||
          chunkSize < 1 ||
          chunkSize > fileTransferV3FramePayloadSize ||
          chunkSize > windowSize ||
          hasMaxChunkSize != hasMaxWindowSize ||
          (hasCompleteFlowExtension &&
              (maxChunkSize is! int ||
                  maxWindowSize is! int ||
                  maxChunkSize < chunkSize ||
                  maxChunkSize > fileTransferV3FramePayloadSize ||
                  maxChunkSize % fileTransferV3LegacyFramePayloadSize != 0 ||
                  maxWindowSize < windowSize ||
                  maxWindowSize > fileTransferV3MaxOfferWindowSize ||
                  maxWindowSize % maxChunkSize != 0))) {
        throw const FileTransferV3MetadataException('invalid_metadata');
      }
      return FileTransferV3Metadata(
        checksumAlgorithm: isFolder
            ? fileTransferFolderChecksumAlgorithm
            : fileTransferV3ChecksumAlgorithm,
        checksumValue: checksumValue,
        checksumDeferred: checksumDeferred,
        chunkSize: chunkSize,
        windowSize: windowSize,
        maxChunkSize: hasCompleteFlowExtension ? maxChunkSize as int : null,
        maxWindowSize: hasCompleteFlowExtension ? maxWindowSize as int : null,
        folder: folder,
      );
    } on FileTransferV3MetadataException {
      rethrow;
    } catch (_) {
      throw const FileTransferV3MetadataException('invalid_metadata');
    }
  }
}

FileTransferV3FlowParameters selectFileTransferV3FlowParameters({
  required FileTransferV3Metadata offer,
  required FileTransferV3FlowParameters localLimits,
}) {
  if (!offer.supportsFlowNegotiation) {
    final chunkSize = offer.chunkSize;
    final windowSize = offer.windowSize;
    final ackIntervalSize = math.min(
      windowSize,
      math.max(fileTransferV3LegacyAckIntervalSize, chunkSize),
    );
    return FileTransferV3FlowParameters(
      chunkSize: chunkSize,
      ackIntervalSize: ackIntervalSize,
      windowSize: windowSize,
    );
  }
  final chunkSize = math.min(localLimits.chunkSize, offer.maxChunkSize!);
  final maximumWindow = math.min(localLimits.windowSize, offer.maxWindowSize!);
  final windowSize = maximumWindow - (maximumWindow % chunkSize);
  final maximumAck = math.min(localLimits.ackIntervalSize, windowSize);
  final ackIntervalSize = math.max(
    chunkSize,
    maximumAck - (maximumAck % chunkSize),
  );
  return FileTransferV3FlowParameters(
    chunkSize: chunkSize,
    ackIntervalSize: ackIntervalSize,
    windowSize: windowSize,
    negotiated: true,
  );
}
