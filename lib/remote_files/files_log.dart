import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What the file manager's copies went through (asked, started, placed,
/// failed), with transfer ids and states only: no file names or paths. In
/// files.log next to the app's data, kept under 1 MB (one previous file is
/// kept), so a copy that got stuck can be followed afterwards.
abstract final class FilesLog {
  static IOSink? _sink;
  static Future<IOSink?>? _opening;
  static int _written = 0;
  static const _limit = 1024 * 1024;

  /// Tests leave the disk alone.
  static bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  static void write(String line) {
    if (!enabled) {
      return;
    }
    final now = DateTime.now().toIso8601String();
    unawaited(
      _append('${now.substring(0, 10)} ${now.substring(11, 23)} $line'),
    );
  }

  /// The first characters of an id, enough to follow one copy.
  static String id(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);

  static Future<void> _append(String line) async {
    final sink = _sink ?? await (_opening ??= _open());
    if (sink == null) {
      return;
    }
    sink.writeln(line);
    _written += line.length + 1;
    if (_written > _limit) {
      _sink = null;
      _opening = null;
      await sink.close();
    }
  }

  static Future<IOSink?> _open() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'files.log'));
      if (await file.exists() && await file.length() > _limit) {
        await file.rename(p.join(dir.path, 'files.1.log'));
      }
      _written = await file.exists() ? await file.length() : 0;
      return _sink = file.openWrite(mode: FileMode.append);
    } catch (_) {
      return null;
    }
  }
}
