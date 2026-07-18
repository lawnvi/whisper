import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device list routes desktop quick send through trusted peers', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains('DesktopQuickSendInbox.shared'));
    expect(source, contains('DesktopQuickSendHotKeyController'));
    expect(source, contains('candidate.auth &&'));
    expect(source, contains('candidate.identityPublicKey.isNotEmpty'));
    expect(source, contains('socketManager.isConnectedTo(candidate.uid)'));
    expect(source, contains('_desktopQuickSendInbox.sendPendingTo'));
    expect(
      source,
      contains('trustedIdentityHashFor: _trustedDeviceIdentityHash'),
    );
    expect(source, contains('sendQuickTextToAcknowledged'));
    expect(source, contains("source: 'desktop-quick-send'"));
    expect(source, contains('jsonEncode(<String>[draftId, pinnedHash])'));
    expect(source, contains('sendFile: _sendDesktopQuickSendFile'));
    expect(source, contains('sendQuickFileToDurably'));
    expect(source, contains("source: 'desktop-quick-send-file'"));
    expect(source, isNot(contains('FolderTransferStager')));
    expect(source, contains('takePendingRejection'));
    expect(source, contains('desktopQuickSendDraftLimit'));
    expect(source, contains('desktopQuickSendClipboardSnapshotUnavailable'));
    expect(source, contains('desktopQuickSendFailedRetained'));
    expect(source, contains('desktopQuickSendTargetConflict'));
    expect(source, contains('desktopQuickSendTargetNeedsReselection'));
    expect(source, contains('Icons.verified_user_rounded'));
    expect(source, contains('e2eeTrustedConnection'));
  });

  test('desktop toolbar leaves quick send to native entry points', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, isNot(contains('_buildDesktopQuickSendAction')));
    expect(source, isNot(contains('Icons.outbox_outlined')));
    expect(source, contains('DesktopQuickSendHotKeyController'));
  });

  test(
    'ordinary startup keeps restored quick-send drafts in the background',
    () {
      final source = File('lib/page/deviceList.dart').readAsStringSync();

      expect(source, contains('takePresentationRequest()'));
      expect(source, contains('_lastPresentedDesktopQuickSendDraftId ='));
      expect(source, contains('_desktopQuickSendInbox.drafts.last.id'));
    },
  );

  test('desktop quick-send copy is localized in all supported languages', () {
    for (final path in <String>[
      'lib/l10n/app_zh.arb',
      'lib/l10n/app_en.arb',
      'lib/l10n/app_es.arb',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('"desktopQuickSendTitle"'), reason: path);
      expect(source, contains('"desktopQuickSendChooseDevice"'), reason: path);
      expect(
        source,
        contains('"desktopQuickSendFailedRetained"'),
        reason: path,
      );
      expect(source, contains('"desktopQuickSendDraftLimit"'), reason: path);
      expect(source, contains('"desktopQuickSendFileLimit"'), reason: path);
      expect(source, contains('"desktopQuickSendTextLimit"'), reason: path);
      expect(source, contains('"desktopQuickSendInvalidPath"'), reason: path);
      expect(
        source,
        contains('"desktopQuickSendClipboardSnapshotUnavailable"'),
        reason: path,
      );
      expect(
        source,
        contains('"desktopQuickSendTargetConflict"'),
        reason: path,
      );
      expect(
        source,
        contains('"desktopQuickSendTargetNeedsReselection"'),
        reason: path,
      );
    }
  });

  test('folder packaging is absent from quick send and conversation', () {
    for (final path in <String>[
      'lib/state/desktop_quick_send_inbox.dart',
      'lib/page/deviceList.dart',
      'lib/page/conversation.dart',
      'lib/widget/chat_composer.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('stageDirectory')), reason: path);
      expect(source, isNot(contains('sendFolder')), reason: path);
      expect(source, isNot(contains('folderSendFailed')), reason: path);
    }
  });
}
