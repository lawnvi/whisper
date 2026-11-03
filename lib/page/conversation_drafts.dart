import 'package:flutter/foundation.dart' show immutable;
import 'package:whisper/helper/desktop_clipboard_image.dart';

/// What was being written to one device, when its conversation left the screen.
@immutable
class ComposerDraft {
  const ComposerDraft({
    this.text = '',
    this.files = const [],
    this.images = const [],
  });

  final String text;
  final List<ClipboardFileDraft> files;
  final List<ClipboardImageDraft> images;

  bool get isEmpty => text.isEmpty && files.isEmpty && images.isEmpty;
}

/// A conversation is rebuilt whenever another device or page was on screen, and
/// what was being written must still be there. Only for as long as the app runs:
/// it is unsent writing and does not belong on the disk.
final class ComposerDrafts {
  ComposerDrafts();

  static final shared = ComposerDrafts();

  final Map<String, ComposerDraft> _byPeer = {};

  ComposerDraft? of(String peerId) => _byPeer[peerId];

  void keep(String peerId, ComposerDraft draft) {
    if (draft.isEmpty) {
      _byPeer.remove(peerId);
    } else {
      _byPeer[peerId] = draft;
    }
  }

  void forget(String peerId) => _byPeer.remove(peerId);
}
