import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/transfer_failure_message.dart';
import 'package:whisper/l10n/app_localizations_en.dart';

void main() {
  test(
    'transfer failures explain the recovery action without exposing raw errors',
    () {
      final l10n = AppLocalizationsEn();
      expect(transferFailureMessage(l10n, 'storage'), l10n.transferStorageHelp);
      expect(transferFailureMessage(l10n, 'source'), l10n.transferSourceHelp);
      expect(
        transferFailureMessage(l10n, 'integrity'),
        l10n.transferIntegrityHelp,
      );
      expect(transferFailureMessage(l10n, 'unknown'), l10n.transferRetryHelp);
    },
  );
}
