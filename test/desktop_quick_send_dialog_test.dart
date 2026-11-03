import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/state/desktop_quick_send_inbox.dart';
import 'package:whisper/widget/desktop_quick_send_dialog.dart';
import 'package:whisper/widget/glass_dialog.dart';
import 'package:whisper/widget/quick_send_chooser.dart';

void main() {
  test('flattens drafts into texts and files in their original order', () {
    final items = desktopQuickSendItems(const <DesktopQuickSendDraft>[
      DesktopQuickSendDraft(
        id: 'draft-1',
        source: DesktopQuickSendSource.clipboardShortcut,
        text: 'hello',
        filePaths: <String>[],
        receivedAt: 1,
      ),
      DesktopQuickSendDraft(
        id: 'draft-2',
        source: DesktopQuickSendSource.systemService,
        text: '',
        filePaths: <String>['/tmp/a/photo.jpg', '/tmp/a/notes.pdf'],
        receivedAt: 2,
      ),
    ]);

    expect(items.map((item) => item.isText), <bool>[true, false, false]);
    expect(items[1].name, 'photo.jpg');
    expect(items[1].isVisualMedia, isTrue);
    expect(items[2].name, 'notes.pdf');
    expect(items[2].isVisualMedia, isFalse);
  });
}
