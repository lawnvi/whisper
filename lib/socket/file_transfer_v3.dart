import 'dart:convert';
import 'dart:math' as math;

const int fileTransferV3ProtocolVersion = 3;
const int fileTransferV3FramePayloadSize = 512 * 1024;
const int fileTransferV3AckIntervalSize = 2 * 1024 * 1024;
// 发送窗口必须小于接收端 BoundedReceiveQueue 的 8MiB 预算:整窗未确认帧
// 全部在途时也只应触发接收侧 pause/resume,绝不能触发 overflow 断联。
const int fileTransferV3WindowSize = 4 * 1024 * 1024;
// 接收端对 offer 声明的发送窗口做有界区间校验(而非与本端常量精确相等):
// 升级改变本端窗口常量后,旧版本对端或本端 DB 里升级前创建的 offer 仍可
// 续传。上界容忍历史最大的 16MiB 窗口并留出余量;接收侧背压是优雅
// pause,更大的声明窗口只会更早触发 pause/resume,不会 overflow 断联。
const int fileTransferV3MaxOfferWindowSize = 32 * 1024 * 1024;
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
      // 身份字段(协议版本、校验算法/值)精确校验;节奏字段
      // (chunkSize/windowSize)只做安全区间校验:窗口落在
      // [一帧, fileTransferV3MaxOfferWindowSize] 且为帧长整数倍,
      // chunk 为正且不超过窗口。避免升级改动节奏常量后,
      // 升级前中断的传输被 invalid_metadata 永久拒绝。
      if (protocolVersion != fileTransferV3ProtocolVersion ||
          checksumAlgorithm != fileTransferV3ChecksumAlgorithm ||
          checksumValue is! String ||
          !_sha256Hex.hasMatch(checksumValue) ||
          chunkSize is! int ||
          windowSize is! int ||
          windowSize < fileTransferV3FramePayloadSize ||
          windowSize > fileTransferV3MaxOfferWindowSize ||
          windowSize % fileTransferV3FramePayloadSize != 0 ||
          chunkSize < 1 ||
          chunkSize > windowSize) {
        throw const FileTransferV3MetadataException('invalid_metadata');
      }
      return FileTransferV3Metadata(
        checksumValue: checksumValue,
        chunkSize: chunkSize,
        windowSize: windowSize,
      );
    } on FileTransferV3MetadataException {
      rethrow;
    } catch (_) {
      throw const FileTransferV3MetadataException('invalid_metadata');
    }
  }

  /// 发送端续传/重发 offer 时,用当前协议节奏常量重建 offer 元数据:
  /// 身份字段(校验算法与校验值)原样保留,chunkSize/windowSize 等节奏
  /// 字段刷新为本端当前常量。DB 里存的 offer content 是创建时序列化的,
  /// 升级改动节奏常量后原样重发会被旧校验规则的对端拒绝。
  ///
  /// content 不可解析或缺少身份字段时返回 null,调用方应原样重发。
  static String? refreshOfferContent(String? content) {
    try {
      final decoded = jsonDecode(content ?? '');
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final checksumValue = decoded['checksumValue'];
      if (decoded['checksumAlgorithm'] != fileTransferV3ChecksumAlgorithm ||
          checksumValue is! String ||
          !_sha256Hex.hasMatch(checksumValue)) {
        return null;
      }
      return jsonEncode(
        FileTransferV3Metadata(checksumValue: checksumValue).toJson(),
      );
    } catch (_) {
      return null;
    }
  }
}
