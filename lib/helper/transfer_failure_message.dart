import 'package:whisper/l10n/app_localizations.dart';

String transferFailureMessage(AppLocalizations l10n, String reason) =>
    _reasonHelp(l10n, reason) ?? l10n.transferRetryHelp;

/// For a toast, which has no message bubble beside it to show what failed.
/// An unrecognised reason says only that the transfer failed rather than
/// pointing at the connection.
String transferFailureNotice(AppLocalizations l10n, String reason) =>
    _reasonHelp(l10n, reason) ?? l10n.fileTransferFailedNotice;

String? _reasonHelp(AppLocalizations l10n, String reason) => switch (reason) {
  'storage' => l10n.transferStorageHelp,
  'source' => l10n.transferSourceHelp,
  'integrity' || 'resume_proof_mismatch' => l10n.transferIntegrityHelp,
  'queue_full' => l10n.transferQueueHelp,
  'folder_unsupported' => l10n.folderSendUnsupported,
  'trust_revoked' ||
  'device_deleted' ||
  'identity_replaced' => l10n.transferTrustHelp,
  _ => null,
};
