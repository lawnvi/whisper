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
    final protocolVersion = json['protocolVersion'];
    final actionName = json['action'];
    final transferId = json['transferId'];
    final durableOffset = json['durableOffset'];
    final size = json['size'];
    final errorCode = json['errorCode'];
    final errorMessage = json['errorMessage'];
    if (protocolVersion is! int ||
        actionName is! String ||
        transferId is! String ||
        durableOffset is! int ||
        size is! int ||
        errorCode is! String ||
        errorMessage is! String) {
      throw const FormatException('invalid file transfer control fields');
    }
    FileTransferV3Action action;
    try {
      action = FileTransferV3Action.values.byName(actionName);
    } on ArgumentError {
      throw const FormatException('unknown file transfer control action');
    }
    return FileTransferV3Control(
      protocolVersion: protocolVersion,
      action: action,
      transferId: transferId,
      durableOffset: durableOffset,
      size: size,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );
  }
}
