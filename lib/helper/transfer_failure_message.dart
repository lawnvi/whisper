import 'package:whisper/l10n/app_localizations.dart';

String transferFailureMessage(AppLocalizations l10n, String reason) =>
    switch (reason) {
      'storage' => l10n.transferStorageHelp,
      'source' => l10n.transferSourceHelp,
      'integrity' || 'resume_proof_mismatch' => l10n.transferIntegrityHelp,
      'queue_full' => l10n.transferQueueHelp,
      'trust_revoked' ||
      'device_deleted' ||
      'identity_replaced' => l10n.transferTrustHelp,
      _ => l10n.transferRetryHelp,
    };
