import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'atomic_file_move.dart';

/// "report.pdf", then "report 2.pdf", "report 3.pdf"…: what is put in a
/// folder someone chose (into a shared folder, dragged in, pasted).
Iterable<String> spacedNames(String name) sync* {
  yield name;
  final stem = p.basenameWithoutExtension(name);
  final extension = p.extension(name);
  for (var n = 2; ; n++) {
    yield '$stem $n$extension';
  }
}

/// "report.pdf", then "report-1.pdf", "report-2.pdf"…: received files. A
/// received [folder] keeps its whole name before the number ("v1.2-1").
Iterable<String> dashedNames(String name, {bool folder = false}) sync* {
  yield name;
  final extension = folder ? '' : p.extension(name);
  final stem = name.substring(0, name.length - extension.length);
  for (var n = 1; ; n++) {
    yield '$stem-$n$extension';
  }
}

/// Past this many taken names something else is wrong.
const int _maxNames = 10000;

/// Moves [source], a file or a folder, into [directory] under the first of
/// [names] that nothing is at, and returns the path it took; null when
/// [source] is on another volume. Nothing already there is replaced, not
/// even an empty folder: the system checks and moves in one step
/// ([movePathWithoutOverwrite]). Only where it can't (some network and FUSE
/// volumes, older Android) is a name checked first and then taken, which
/// leaves a moment in which something else could take it.
Future<String?> moveToFreeName(
  String source,
  String directory,
  Iterable<String> names,
) async {
  var tried = 0;
  for (final name in names) {
    if (++tried > _maxNames) break;
    final target = _inside(directory, name);
    switch (movePathWithoutOverwrite(source, target)) {
      case PathMoveResult.moved:
        return target;
      case PathMoveResult.destinationExists:
        continue;
      case PathMoveResult.otherVolume:
        return null;
      case PathMoveResult.unsupported:
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        await _rename(source, target);
        return target;
    }
  }
  throw FileSystemException('no free name', directory);
}

/// Puts [source], a file or a folder, into [directory] under the first free
/// of [names], as [moveToFreeName] does, and returns the path it took.
///
/// Where it can't be moved (another volume; on Windows, a file still open
/// somewhere), and with [copy], it is copied in under a hidden name first
/// and that is moved the same way, so a half-copied file never shows under
/// the name. [source] is then removed unless [copy]; one that can't be is
/// kept, and [kept] hears why.
Future<String> placeWithoutOverwrite(
  String source,
  String directory,
  Iterable<String> names, {
  bool copy = false,
  void Function(FileSystemException error)? kept,
}) async {
  if (!copy) {
    try {
      final moved = await moveToFreeName(source, directory, names);
      if (moved != null) return moved;
    } on FileSystemException {
      // Held open, or refused here: a copy may still get through.
    }
  }
  final staged = _inside(directory, '.whisper-${_nonce()}.part');
  final String placed;
  try {
    await _copy(source, staged);
    placed =
        await moveToFreeName(staged, directory, names) ??
        (throw FileSystemException('copy left the folder', staged));
  } catch (_) {
    await _remove(staged);
    rethrow;
  }
  if (!copy) {
    try {
      await _delete(source);
    } on FileSystemException catch (error) {
      kept?.call(error);
    }
  }
  return placed;
}

/// [name] in [directory]; a name that would leave it is refused.
String _inside(String directory, String name) {
  final target = p.join(directory, name);
  if (name.isEmpty || !p.equals(p.dirname(target), directory)) {
    throw ArgumentError.value(name, 'name', 'not a plain name');
  }
  return target;
}

String _nonce() {
  final random = Random.secure();
  return List<String>.generate(
    8,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Future<void> _rename(String source, String target) async {
  if (await FileSystemEntity.isDirectory(source)) {
    await Directory(source).rename(target);
  } else {
    await File(source).rename(target);
  }
}

Future<void> _copy(String source, String target) async {
  if (await FileSystemEntity.type(source, followLinks: false) ==
      FileSystemEntityType.directory) {
    await _copyTree(Directory(source), Directory(target));
  } else {
    await File(source).copy(target);
  }
}

/// Files and folders; links are left out.
Future<void> _copyTree(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final entity in from.list(followLinks: false)) {
    final target = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyTree(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

Future<void> _delete(String path) async {
  if (await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  } else {
    await File(path).delete();
  }
}

Future<void> _remove(String path) async {
  try {
    await _delete(path);
  } on FileSystemException {
    // Never made, or already gone.
  }
}
