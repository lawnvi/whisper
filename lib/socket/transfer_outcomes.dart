/// How transfers ended, for callers and diagnostics.
library;

import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';

/// 与 svrmanager `_buildMessage` 现签名逐字对应(msg/fileName/path/uid/fileTimestamp 原本未标类型)。
typedef TransferMessageBuilder =
    MessageData Function(
      MessageEnum type,
      String content,
      dynamic msg,
      dynamic fileName,
      int size,
      bool clipboard, {
      String md5,
      dynamic path,
      dynamic uid,
      dynamic fileTimestamp,
      String? receiverOverride,
    });

/// How an attempt to send a folder ended, for the caller to explain.
enum FolderSendOutcome {
  sent,
  notConnected,
  peerUnsupported,
  invalidName,
  unreadable,
  tooManyEntries,
  tooLarge,
  rejected,
}

enum FileTransferDiagnosticKind {
  outgoingFailed,
  incomingFailed,
  resumeResetDeferred,
  reservationCleanupFailed,
  completionDispatchFailed,
  temporaryFileCleanupFailed,
  visibilityNotificationFailed,
}
