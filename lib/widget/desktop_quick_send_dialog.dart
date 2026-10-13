import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/state/desktop_quick_send_inbox.dart';
import 'package:whisper/widget/glass_dialog.dart';
import 'package:whisper/widget/quick_send_chooser.dart';

Future<String?> showDesktopQuickSendDialog(
  BuildContext context, {
  required List<DesktopQuickSendDraft> drafts,
  required ValueListenable<List<QuickSendTarget>> targets,
  String? initialPeerId,
}) {
  return showWhisperDialog<String>(
    context,
    builder: (context) => QuickSendChooser(
      layout: QuickSendChooserLayout.dialog,
      items: desktopQuickSendItems(drafts),
      targets: targets,
      initialTargetId: initialPeerId,
    ),
  );
}

List<QuickSendItem> desktopQuickSendItems(List<DesktopQuickSendDraft> drafts) {
  return <QuickSendItem>[
    for (final draft in drafts) ...[
      if (draft.text.isNotEmpty) QuickSendItem.text(draft.text),
      for (final path in draft.filePaths)
        QuickSendItem.file(name: p.basename(path), source: path),
    ],
  ];
}
