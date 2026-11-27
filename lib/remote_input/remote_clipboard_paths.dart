import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper/socket/wire_input_policy.dart'
    show isCanonicalTransferId;

const String _clipboardCacheFolderName = 'whisper_remote_clipboard';
const String _clipboardStagingFolderName = 'whisper_remote_clipboard_staging';

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

/// App-private base directory for clipboard paste caches and outgoing
/// screenshot staging files (never Downloads). Falls back to system temp in
/// headless unit tests where `path_provider` plugins are unavailable.
Future<Directory> defaultPrivateClipboardDirectory() async {
  try {
    return await getApplicationSupportDirectory();
  } on MissingPluginException {
    return Directory.systemTemp;
  } on UnsupportedError {
    return Directory.systemTemp;
  }
}

/// The folder a remote offer's files are written to, and deleted with, under
/// [base]. Both names come from the peer, so the folder has to stay inside
/// `whisper_remote_clipboard`.
Directory remoteClipboardOfferDirectory(
  String base,
  String sessionId,
  String offerId,
) {
  final root = p.join(base, _clipboardCacheFolderName);
  final path = p.normalize(p.join(root, sessionId, offerId));
  if (!isSafeClipboardName(sessionId) ||
      !isCanonicalTransferId(offerId) ||
      !p.isWithin(root, path)) {
    throw const FormatException('remote clipboard offer outside its folder');
  }
  return Directory(path);
}

/// Private staging folder for one outgoing clipboard image transfer under
/// [base], deleted when the transfer completes, fails, cancels, or on startup.
Directory remoteClipboardStagingDirectory(String base, String transferId) {
  final root = p.join(base, _clipboardStagingFolderName);
  final path = p.normalize(p.join(root, transferId));
  if (!isCanonicalTransferId(transferId) || !p.isWithin(root, path)) {
    throw const FormatException('remote clipboard staging outside its folder');
  }
  return Directory(path);
}

/// Removes leftover clipboard cache and screenshot staging directories from
/// an earlier run that exited abruptly.
Future<void> cleanupRemoteClipboardDirectories(String base) async {
  for (final name in const <String>[
    _clipboardStagingFolderName,
    _clipboardCacheFolderName,
  ]) {
    final dir = Directory(p.join(base, name));
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } on FileSystemException {
      // Best-effort cleanup at startup.
    }
  }
}
