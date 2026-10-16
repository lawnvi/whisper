import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The documents folder, which holds the database. On Linux path_provider
/// asks the `xdg-user-dir` command for it, and minimal installs lack that
/// command; path_provider then has no answer and the database cannot open.
Future<Directory> userDocumentsDirectory() async {
  if (!Platform.isLinux) {
    return getApplicationDocumentsDirectory();
  }
  try {
    return await getApplicationDocumentsDirectory();
  } on MissingPlatformDirectoryException {
    final directory = linuxUserDirectory('DOCUMENTS', 'Documents');
    await directory.create(recursive: true);
    return directory;
  }
}

/// The downloads folder, or null on a platform without one. Linux has the
/// same gap as [userDocumentsDirectory].
Future<Directory?> userDownloadsDirectory() async {
  final directory = await getDownloadsDirectory();
  if (directory != null || !Platform.isLinux) {
    return directory;
  }
  return linuxUserDirectory('DOWNLOAD', 'Downloads');
}

/// Reads the folder [name] from user-dirs.dirs, as `xdg-user-dir` would, so
/// the answer stays the same with or without the command. Where it is not
/// set there, it is [fallback] in the home folder.
Directory linuxUserDirectory(
  String name,
  String fallback, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? '';
  final configHome = env['XDG_CONFIG_HOME'];
  final config = File(
    p.join(
      configHome == null || configHome.isEmpty
          ? p.join(home, '.config')
          : configHome,
      'user-dirs.dirs',
    ),
  );
  final entry = RegExp('^XDG_${name}_DIR="(.*)"\$');
  try {
    for (final line in config.readAsLinesSync()) {
      final value = entry.firstMatch(line.trim())?.group(1);
      if (value == null) {
        continue;
      }
      if (value.startsWith(r'$HOME')) {
        return Directory(home + value.substring(r'$HOME'.length));
      }
      if (p.isAbsolute(value)) {
        return Directory(value);
      }
    }
  } on FileSystemException {
    // Never set up: no folder has been chosen.
  }
  return Directory(p.join(home, fallback));
}
