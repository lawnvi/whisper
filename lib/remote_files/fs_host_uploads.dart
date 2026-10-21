import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'fs_host_files.dart';
import 'fs_paths.dart';
import 'fs_placement.dart';
import 'fs_platform.dart';

/// A file being written from another device's mounted folder: a hidden
/// copy next to it ([FsUploads.isTemp]) that takes the writes, in the order
/// they come.
class FsUpload {
  FsUpload._({
    required this.id,
    required this.owner,
    required this.device,
    required this.rootId,
    required this.target,
    required this.temp,
    required this.base,
    required RandomAccessFile file,
    required this.size,
  }) : _file = file;

  final String id;

  /// The browse session it belongs to; it goes when that ends.
  final String owner;

  /// The writing device's name, for a copy kept beside a file changed
  /// here meanwhile.
  final String device;
  final String rootId;

  /// The file it replaces once done.
  final String target;
  final String temp;

  /// What the file was when writing began: if it is not that any more at
  /// the end, it was changed here too.
  final ({int size, int modifiedMs}) base;
  final RandomAccessFile _file;
  int size;
  DateTime used = DateTime.now();
  Future<void> _turn = Future.value();
  bool _closed = false;

  /// One at a time: a file takes one operation after another.
  Future<T> _serially<T>(Future<T> Function() work) {
    used = DateTime.now();
    final result = _turn.then((_) {
      if (_closed) {
        throw const FsPathException('not found');
      }
      return work();
    });
    _turn = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<int> write(int offset, Uint8List data) => _serially(() async {
    await _file.setPosition(offset);
    await _file.writeFrom(data);
    if (offset + data.length > size) {
      size = offset + data.length;
    }
    return size;
  });

  Future<void> resize(int length) => _serially(() async {
    await _file.truncate(length);
    size = length;
  });

  /// What was written so far, for the device reading back what it wrote.
  Future<Uint8List> read(int offset, int length) => _serially(() async {
    final buffer = Uint8List((size - offset).clamp(0, length));
    await _file.setPosition(offset);
    var got = 0;
    while (got < buffer.length) {
      final n = await _file.readInto(buffer, got);
      if (n == 0) {
        break;
      }
      got += n;
    }
    return Uint8List.sublistView(buffer, 0, got);
  });

  Future<void> _close() => _serially(() async {
    _closed = true;
    try {
      await _file.flush();
    } finally {
      await _file.close();
    }
  });
}

/// Files other devices write here through their mounted folders. Each is
/// written into a hidden copy beside it, which closing puts in its place
/// with one rename: the file is as it was or as written, never half of
/// either. A file that was changed here while it was being written there
/// is left alone; what was written is kept next to it, named for the
/// device that wrote it, and so is what could not replace a file still
/// held open here.
class FsUploads {
  FsUploads(this.files, {Random? random}) : _random = random ?? Random.secure();

  final FsHostFiles files;
  final Random _random;
  final _open = <String, FsUpload>{};

  /// More open at once from one session is a device gone wrong.
  static const maxPerOwner = 64;

  /// Not written to for this long: the device that was writing is gone.
  static const idleLimit = Duration(minutes: 30);

  static final _tempName = RegExp(r'^\.whisper-[0-9a-f]{16}\.tmp$');

  /// One of the hidden copies being written, which listings leave out.
  static bool isTemp(String name) => _tempName.hasMatch(name);

  FsUpload? operator [](String id) => _open[id];

  /// Starts writing [relative] (an existing file): from what it holds now,
  /// or from nothing when [truncate].
  Future<FsUpload> open({
    required String owner,
    required String device,
    required String rootId,
    required String relative,
    required bool truncate,
  }) async {
    await sweep();
    if (_open.values.where((upload) => upload.owner == owner).length >=
        maxPerOwner) {
      throw const FsPathException('busy');
    }
    final target = await files.resolver.resolveExisting(rootId, relative);
    final stat = await FileStat.stat(target);
    if (stat.type != FileSystemEntityType.file) {
      throw const FsPathException('not a file');
    }
    final id = [
      for (var i = 0; i < 8; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final temp = p.join(p.dirname(target), '.whisper-$id.tmp');
    if (truncate) {
      await File(temp).create(exclusive: true);
    } else {
      await File(target).copy(temp);
    }
    final RandomAccessFile file;
    try {
      FsPlatform.setHiddenWindows(temp, true);
      FsPlatform.copyMode(temp, stat.mode);
      // Reading and writing anywhere in it, nothing cut off.
      file = await File(temp).open(mode: FileMode.append);
    } catch (_) {
      await _delete(temp);
      rethrow;
    }
    final upload = FsUpload._(
      id: id,
      owner: owner,
      device: device,
      rootId: rootId,
      target: target,
      temp: temp,
      base: (size: stat.size, modifiedMs: stat.modified.millisecondsSinceEpoch),
      file: file,
      size: truncate ? 0 : stat.size,
    );
    _open[id] = upload;
    return upload;
  }

  /// Ends upload [id]: in place of its file when [commit] (modified at
  /// [modifiedMs] if given), else gone. Returns where it went: the file,
  /// or the copy kept beside it.
  Future<String> close(
    String id, {
    required bool commit,
    int? modifiedMs,
  }) async {
    final upload = _open.remove(id);
    if (upload == null) {
      throw const FsPathException('not found');
    }
    try {
      await upload._close();
    } catch (_) {
      await _delete(upload.temp);
      rethrow;
    }
    if (!commit) {
      await _delete(upload.temp);
      return upload.target;
    }
    try {
      if (modifiedMs != null) {
        await File(
          upload.temp,
        ).setLastModified(DateTime.fromMillisecondsSinceEpoch(modifiedMs));
      }
      // A rename keeps the attributes: the file is not to come out hidden.
      FsPlatform.setHiddenWindows(upload.temp, false);
      final now = await _stamp(upload.target);
      var into = upload.target;
      if (now != null && now != upload.base) {
        into = await _beside(upload);
      }
      try {
        await File(upload.temp).rename(into);
      } on FileSystemException {
        if (into != upload.target) {
          rethrow;
        }
        // Held open here (Windows will not replace it): kept beside it.
        into = await _beside(upload);
        await File(upload.temp).rename(into);
      }
      files.invalidate(upload.rootId);
      await FsPlatform.mediaScan([into]);
      return into;
    } catch (_) {
      await _delete(upload.temp);
      rethrow;
    }
  }

  /// "report (MacBook).docx" next to "report.docx".
  static Future<String> _beside(FsUpload upload) {
    final name = p.basename(upload.target);
    final device = upload.device
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), ' ')
        .trim();
    return TransferPlacements.freeName(
      p.dirname(upload.target),
      '${p.basenameWithoutExtension(name)} '
      '(${device.isEmpty ? 'Whisper' : device})${p.extension(name)}',
    );
  }

  static Future<({int size, int modifiedMs})?> _stamp(String path) async {
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) {
      return null;
    }
    return (size: stat.size, modifiedMs: stat.modified.millisecondsSinceEpoch);
  }

  /// Drops what [owner] was writing: its session ended.
  Future<void> discardOwner(String owner) async {
    for (final upload in _open.values.toList()) {
      if (upload.owner == owner) {
        await _discard(upload);
      }
    }
  }

  /// Drops uploads nobody wrote to for [idleLimit].
  Future<void> sweep() async {
    final now = DateTime.now();
    for (final upload in _open.values.toList()) {
      if (now.difference(upload.used) > idleLimit) {
        await _discard(upload);
      }
    }
  }

  Future<void> _discard(FsUpload upload) async {
    if (!identical(_open.remove(upload.id), upload)) {
      return;
    }
    try {
      await upload._close();
    } catch (_) {
      // Removed below all the same.
    }
    await _delete(upload.temp);
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
