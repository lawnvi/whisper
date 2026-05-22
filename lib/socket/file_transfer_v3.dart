const int fileTransferV3ProtocolVersion = 3;
const int fileTransferV3FramePayloadSize = 512 * 1024;
const int fileTransferV3AckIntervalSize = 2 * 1024 * 1024;
const int fileTransferV3WindowSize = 16 * 1024 * 1024;

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
    this.protocolVersion = fileTransferV3ProtocolVersion,
  });

  final int protocolVersion;
  final FileTransferV3Action action;
  final String transferId;
  final int durableOffset;
  final int size;
  final String errorCode;
  final String errorMessage;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'protocolVersion': protocolVersion,
        'action': action.name,
        'transferId': transferId,
        'durableOffset': durableOffset,
        'size': size,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
      };

  factory FileTransferV3Control.fromJson(Map<String, dynamic> json) {
    final actionName =
        json['action'] as String? ?? FileTransferV3Action.error.name;
    return FileTransferV3Control(
      protocolVersion:
          json['protocolVersion'] as int? ?? fileTransferV3ProtocolVersion,
      action: FileTransferV3Action.values.firstWhere(
        (item) => item.name == actionName,
        orElse: () => FileTransferV3Action.error,
      ),
      transferId: json['transferId'] as String? ?? '',
      durableOffset: json['durableOffset'] as int? ?? 0,
      size: json['size'] as int? ?? 0,
      errorCode: json['errorCode'] as String? ?? '',
      errorMessage: json['errorMessage'] as String? ?? '',
    );
  }
}
