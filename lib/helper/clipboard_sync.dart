import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/helper.dart' show getClipboardText;

typedef ClipboardTextProvider = Future<String?> Function();
typedef ClipboardFileDraftsProvider = Future<List<ClipboardFileDraft>>
    Function();

Future<String?> readClipboardTextForSync({
  ClipboardTextProvider? textProvider,
  ClipboardFileDraftsProvider? fileDraftsProvider,
}) async {
  try {
    final drafts = await (fileDraftsProvider ??
        const DesktopClipboardFileReader().readFileDrafts)();
    if (drafts.isNotEmpty) {
      return null;
    }
  } catch (_) {
    // File clipboard detection is best-effort; text sync should keep working
    // when a desktop platform does not expose that capability.
  }

  return (textProvider ?? getClipboardText)();
}
