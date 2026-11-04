import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show SqliteException;

/// What Whisper did lately, on this device, for someone to send along when
/// something is wrong. It leaves only when they send it.
///
/// Only what [PrivacyLog] lets through goes in, and of an error its type, its
/// code and where it happened. Never `error.toString()`: that is where file names,
/// addresses and text end up.
class AppLog {
  AppLog({this.maxFileBytes = 512 * 1024});

  static final shared = AppLog();
  static const _flushAfter = Duration(seconds: 1);
  static const _maxPending = 2000;
  static const _maxStackLines = 12;

  /// One file this large, and the one before it.
  final int maxFileBytes;

  Directory? _directory;
  final _pending = <String>[];
  Timer? _flush;
  Future<void> _writing = Future<void>.value();

  File get _current => File(p.join(_directory!.path, 'whisper.log'));
  File get _previous => File(p.join(_directory!.path, 'whisper.1.log'));

  Future<void> start(Directory directory) async {
    await directory.create(recursive: true);
    _directory = directory;
    _schedule();
  }

  void write(String line) {
    _pending.add('${DateTime.now().toIso8601String()} $line');
    if (_pending.length > _maxPending) {
      _pending.removeRange(0, _pending.length - _maxPending);
    }
    _schedule();
  }

  void recordError(String where, Object? error, [StackTrace? stack]) {
    write(
      jsonEncode(<String, Object?>{
        'event': 'error',
        'where': where,
        ...describeError(error),
        if (stack != null)
          'stack': stack
              .toString()
              .split('\n')
              .where((line) => line.isNotEmpty)
              .take(_maxStackLines)
              .toList(),
      }),
    );
  }

  /// What can be said of an error without repeating what it says.
  static Map<String, Object?> describeError(Object? error) {
    if (error == null) return const {};
    final os = switch (error) {
      FileSystemException(:final osError) => osError,
      SocketException(:final osError) => osError,
      _ => null,
    };
    return <String, Object?>{
      'type': error.runtimeType.toString(),
      if (os != null) ...{'code': os.errorCode, 'os': os.message},
      if (error is SqliteException) ...{
        'code': error.extendedResultCode,
        'os': error.resultCode,
      },
      if (error is PlatformException) 'code': error.code,
    };
  }

  void _schedule() {
    if (_directory == null) return;
    _flush ??= Timer(_flushAfter, () {
      _flush = null;
      unawaited(flush());
    });
  }

  /// Writes what is waiting, in the order it came.
  Future<void> flush() {
    if (_directory == null || _pending.isEmpty) return _writing;
    final lines = '${_pending.join('\n')}\n';
    _pending.clear();
    return _writing = _writing.then((_) => _append(lines));
  }

  Future<void> _append(String lines) async {
    try {
      final current = _current;
      await current.writeAsString(lines, mode: FileMode.append);
      if (await current.length() > maxFileBytes) {
        await current.rename(_previous.path);
      }
    } on FileSystemException {
      // Nothing to tell, and nowhere to write it: a log must not cause trouble.
    }
  }

  /// All that is kept, oldest first.
  Future<String> recent() async {
    if (_directory == null) return '';
    await flush();
    final out = StringBuffer();
    for (final file in [_previous, _current]) {
      if (await file.exists()) {
        out.write(await file.readAsString());
      }
    }
    return out.toString();
  }
}
