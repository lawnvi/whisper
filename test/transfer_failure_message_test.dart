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

  test('a toast keeps known help but does not blame the connection', () {
    final l10n = AppLocalizationsEn();
    expect(transferFailureNotice(l10n, 'storage'), l10n.transferStorageHelp);
    expect(transferFailureNotice(l10n, 'queue_full'), l10n.transferQueueHelp);
    expect(
      transferFailureNotice(l10n, 'receiver'),
      l10n.fileTransferFailedNotice,
    );
    // The engine also passes free text for failures that never get a bubble.
    expect(
      transferFailureNotice(l10n, '文件传输队列已满'),
      l10n.fileTransferFailedNotice,
    );
  });
}
