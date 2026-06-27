import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/clipboard_sync.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';

void main() {
  test('skips text sync when clipboard contains copied files', () async {
    var textReads = 0;

    final text = await readClipboardTextForSync(
      fileDraftsProvider: () async => const <ClipboardFileDraft>[
        ClipboardFileDraft(
          path: '/tmp/report.pdf',
          fileName: 'report.pdf',
          size: 1024,
        ),
      ],
      textProvider: () async {
        textReads++;
        return 'report.pdf';
      },
    );

    expect(text, isNull);
    expect(textReads, 0);
  });

  test('returns text sync content when clipboard has no copied files',
      () async {
    final text = await readClipboardTextForSync(
      fileDraftsProvider: () async => const <ClipboardFileDraft>[],
      textProvider: () async => 'hello',
    );

    expect(text, 'hello');
  });

  test('falls back to text sync when file detection is unavailable', () async {
    final text = await readClipboardTextForSync(
      fileDraftsProvider: () async => throw Exception('unavailable'),
      textProvider: () async => 'hello',
    );

    expect(text, 'hello');
  });
}
