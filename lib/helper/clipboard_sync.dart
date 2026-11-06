import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/helper.dart' show getClipboardText;
import 'package:whisper/helper/privacy_log.dart';

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

/// What became of a clipboard change, or of what another device sent.
enum ClipboardSyncStep { sent, skipped, received, frameDropped }

/// Why a local clipboard change went nowhere.
enum ClipboardSyncReason {
  autoSyncOff,
  noTarget,
  unchanged,
  echo,
  empty,
  ownFiles,
  sessionFiles,
  files,
  image,
}

/// One line in the log a user sends along, so "clipboard sync stopped" can be
/// traced. Never what was copied: only which step, why, and how many devices.
void logClipboardSync(
  ClipboardSyncStep step, {
  ClipboardSyncReason? reason,
  int? count,
  Enum? kind,
  Object? error,
}) {
  privacyLog.event(PrivacyEvent.clipboardSync, <PrivacyField, Object>{
    PrivacyField.action: step,
    if (reason != null) PrivacyField.reason: reason,
    if (count != null) PrivacyField.count: count,
    if (kind != null) PrivacyField.kind: kind,
    if (error != null) PrivacyField.errorType: privacyLog.errorType(error),
  });
}
