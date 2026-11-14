import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:whisper/helper/app_private_paths.dart';
import 'package:whisper/state/app_health.dart';

import '../helper/user_directories.dart';

/// The database file, where this platform keeps it. On Linux and Windows that
/// is the Documents folder, which other devices may be allowed to browse: the
/// file and the ones SQLite keeps beside it are Whisper's own, never theirs
/// (see [AppPrivatePaths]).
Future<File> databaseFile() async {
  final file = File('${(await _databaseDirectory()).path}/db.sqlite');
  for (final suffix in const ['', '-wal', '-shm', '-journal']) {
    AppPrivatePaths.add('${file.path}$suffix');
  }
  return file;
}

Future<Directory> _databaseDirectory() async {
  if (Platform.isMacOS) {
    final currentDirectory = await getApplicationSupportDirectory();
    final currentDatabase = File('${currentDirectory.path}/db.sqlite');
    if (await currentDatabase.exists()) {
      return currentDirectory;
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final legacyDirectory = Directory(
        '$home/Library/Containers/com.vireen.whisper/Data/Documents',
      );
      final legacyDatabase = File('${legacyDirectory.path}/db.sqlite');
      if (await migrateLegacyMacOSDatabase(
        legacyDatabase: legacyDatabase,
        destinationDirectory: currentDirectory,
      )) {
        return currentDirectory;
      }
      if (await canOpenMacOSDatabase(legacyDatabase)) {
        return legacyDirectory;
      }
      AppHealth.shared.oldHistoryUnreadable = await legacyDatabase.exists();
    }
    return currentDirectory;
  }
  if (Platform.isIOS) {
    // Documents is the Whisper folder the Files app shows (received files,
    // other devices browsing it): the database lives out of sight, in
    // Application Support, moved there from Documents once.
    final support = await getApplicationSupportDirectory();
    final current = File('${support.path}/db.sqlite');
    if (await current.exists()) {
      return support;
    }
    final documents = await userDocumentsDirectory();
    final legacy = File('${documents.path}/db.sqlite');
    if (await migrateLegacyMacOSDatabase(
      legacyDatabase: legacy,
      destinationDirectory: support,
    )) {
      for (final suffix in const ['', '-wal', '-shm']) {
        try {
          await File('${legacy.path}$suffix').delete();
        } on FileSystemException {
          // Already gone.
        }
      }
      return support;
    }
    if (await legacy.exists()) {
      return documents;
    }
    await support.create(recursive: true);
    return support;
  }
  return userDocumentsDirectory();
}

Future<bool> migrateLegacyMacOSDatabase({
  required File legacyDatabase,
  required Directory destinationDirectory,
}) async {
  final destination = File('${destinationDirectory.path}/db.sqlite');
  if (await destination.exists()) {
    return true;
  }
  if (!await legacyDatabase.exists()) {
    return false;
  }

  await destinationDirectory.create(recursive: true);
  final temporary = File('${destination.path}.migrating');
  Database? source;
  Database? target;
  try {
    if (await temporary.exists()) {
      await temporary.delete();
    }
    source = sqlite3.open(legacyDatabase.path, mode: OpenMode.readOnly);
    target = sqlite3.open(temporary.path);
    await source.backup(target, nPage: -1).drain<void>();
    target.dispose();
    target = null;
    source.dispose();
    source = null;
    await temporary.rename(destination.path);
    return true;
  } catch (_) {
    return false;
  } finally {
    target?.dispose();
    source?.dispose();
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }
}

/// Whether a database left in an old sandboxed install's container can be used
/// where it is. macOS may keep this app out of that container, signed differently
/// as it is: the file is there, and opening it fails. Going ahead with it would
/// leave the app with no database at all, and so no server and no discovery either,
/// with nothing on screen to say so. Its history stays where it is, untouched.
Future<bool> canOpenMacOSDatabase(File database) async {
  if (!await database.exists()) return false;
  Database? opened;
  try {
    opened = sqlite3.open(database.path);
    opened.select('SELECT count(*) FROM sqlite_master');
    return true;
  } catch (_) {
    return false;
  } finally {
    opened?.dispose();
  }
}
