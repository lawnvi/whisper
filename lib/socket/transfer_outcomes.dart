/// How transfers ended, for callers and diagnostics.
library;

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
