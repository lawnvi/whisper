import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:whisper/socket/wire_input_policy.dart'
    show isCanonicalTransferId;

/// A single plain file or folder name from the peer: no separators, not `.`
/// or `..`, no NUL.
bool isSafeClipboardName(String value) {
  return value.isNotEmpty &&
      value.length <= 255 &&
      value != '.' &&
      value != '..' &&
      p.basename(value) == value &&
      !value.contains('\u0000');
}

/// The folder a remote offer's files are written to, and deleted with, under
/// [base]. Both names come from the peer, so the folder has to stay inside
/// `whisper_remote_clipboard`.
Directory remoteClipboardOfferDirectory(
  String base,
  String sessionId,
  String offerId,
) {
  final root = p.join(base, 'whisper_remote_clipboard');
  final path = p.normalize(p.join(root, sessionId, offerId));
  if (!isSafeClipboardName(sessionId) ||
      !isCanonicalTransferId(offerId) ||
      !p.isWithin(root, path)) {
    throw const FormatException('remote clipboard offer outside its folder');
  }
  return Directory(path);
}
