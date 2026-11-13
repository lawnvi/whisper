import 'dart:io';

import 'package:whisper/remote_files/fs_paths.dart' show fsNameProblem;
import 'package:whisper/socket/transfer_file_name.dart' show isFileNameControl;

/// A file or folder name from the other device, made into one this system
/// can hold. On Windows a name is also a path: `\`, `:` or `..` in it would
/// reach outside the mount or a dragged-out file's folder, so whatever
/// [fsNameProblem] refuses there is replaced. `.` and `..` are never names.
/// Control and bidi characters ([isFileNameControl]) become `_` everywhere:
/// they would show a program as a picture in the file manager.
String localFileName(String name, {bool? windows}) {
  final safe = String.fromCharCodes([
    for (final rune in name.replaceAll('/', '∕').runes)
      isFileNameControl(rune) ? 0x5f : rune,
  ]);
  if (safe.isEmpty || safe == '.' || safe == '..') {
    return '_';
  }
  if (!(windows ?? Platform.isWindows) ||
      fsNameProblem(safe, windows: true) == null) {
    return safe;
  }
  final cleaned = safe
      .replaceAll(RegExp(r'[<>:"\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  for (final candidate in [cleaned, '_$cleaned']) {
    if (fsNameProblem(candidate, windows: true) == null) {
      return candidate;
    }
  }
  return '_';
}

/// `folder\name` for a name of this mount, or null when [name] is not a
/// plain Windows name and so could leave [folder].
String? windowsChildPath(String folder, String name) =>
    localFileName(name, windows: true) == name ? '$folder\\$name' : null;
