import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The window stream's lifecycle events (no user content) in a small file
/// next to the app's data, so a problem someone ran into can be looked at
/// afterwards. Kept under 1 MB (one previous file is kept).
abstract final class WindowStreamLog {
  static IOSink? _sink;
  static Future<IOSink?>? _opening;
  static int _written = 0;
  static const _limit = 1024 * 1024;

  static void write(String line) {
    unawaited(
      _append('${DateTime.now().toIso8601String().substring(0, 10)} $line'),
    );
  }

  static Future<void> _append(String line) async {
    final sink = _sink ?? await (_opening ??= _open());
    if (sink == null) {
      return;
    }
    sink.writeln(line);
    _written += line.length + 1;
  }

  static Future<IOSink?> _open() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'window_stream.log'));
      if (await file.exists() && await file.length() > _limit) {
        await file.rename(p.join(dir.path, 'window_stream.1.log'));
      }
      _written = await file.exists() ? await file.length() : 0;
      return _sink = file.openWrite(mode: FileMode.append);
    } catch (_) {
      return null;
    } finally {
      if (_written > _limit) {
        await _sink?.close();
        _sink = null;
        _opening = null;
      }
    }
  }
}
