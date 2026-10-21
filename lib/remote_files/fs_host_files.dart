import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fs_host_uploads.dart';
import 'fs_paths.dart';
import 'fs_platform.dart';

/// One entry of a folder listing, as sent to the browsing device.
class FsEntry {
  const FsEntry({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modifiedMs,
    this.hidden = false,
    this.isLink = false,
  });

  factory FsEntry.fromJson(Map<String, Object?> json) => FsEntry(
    name: json['n'] as String,
    isDir: json['d'] == true,
    size: (json['s'] as num?)?.toInt() ?? 0,
    modifiedMs: (json['m'] as num?)?.toInt() ?? 0,
    hidden: json['h'] == true,
    isLink: json['l'] == true,
  );

  final String name;
  final bool isDir;
  final int size;
  final int modifiedMs;
  final bool hidden;
  final bool isLink;

  FsKind get kind => isDir ? FsKind.folder : fsKindOf(name);

  Map<String, Object?> toJson() => {
    'n': name,
    if (isDir) 'd': true,
    if (!isDir) 's': size,
    'm': modifiedMs,
    if (hidden) 'h': true,
    if (isLink) 'l': true,
  };
}

enum FsKind { folder, image, video, audio, document, archive, code, app, other }

FsKind fsKindOf(String name) {
  final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  const kinds = {
    FsKind.image: {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'heic',
      'heif',
      'webp',
      'bmp',
      'tif',
      'tiff',
      'dng',
      'svg',
    },
    FsKind.video: {
      'mp4',
      'mov',
      'm4v',
      'mkv',
      'avi',
      'webm',
      '3gp',
      'flv',
      'wmv',
    },
    FsKind.audio: {
      'mp3',
      'm4a',
      'aac',
      'flac',
      'wav',
      'ogg',
      'opus',
      'amr',
      'wma',
    },
    FsKind.document: {
      'pdf',
      'doc',
      'docx',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
      'key',
      'pages',
      'numbers',
      'txt',
      'md',
      'rtf',
      'csv',
      'epub',
    },
    FsKind.archive: {
      'zip',
      'rar',
      '7z',
      'tar',
      'gz',
      'tgz',
      'bz2',
      'xz',
      'dmg',
      'iso',
    },
    FsKind.code: {
      'dart',
      'js',
      'ts',
      'py',
      'java',
      'kt',
      'swift',
      'c',
      'h',
      'cpp',
      'go',
      'rs',
      'json',
      'yaml',
      'yml',
      'xml',
      'html',
      'css',
      'sh',
    },
    FsKind.app: {'apk', 'app', 'exe', 'msi', 'pkg', 'deb', 'rpm', 'appimage'},
  };
  for (final entry in kinds.entries) {
    if (entry.value.contains(ext)) {
      return entry.key;
    }
  }
  return FsKind.other;
}

/// One page of a folder's entries: folders first, then names in natural
/// order ("IMG_2" before "IMG_10").
class FsPage {
  const FsPage({
    required this.entries,
    required this.total,
    required this.offset,
  });

  final List<FsEntry> entries;
  final int total;
  final int offset;

  bool get hasMore => offset + entries.length < total;
}

/// The hosting side's file operations, all through [FsPathResolver].
class FsHostFiles {
  FsHostFiles({
    FsPathResolver? resolver,
    Duration listingLifetime = const Duration(seconds: 20),
  }) : resolver = resolver ?? FsPathResolver(defaultFsRoots()),
       _platformRoots = resolver == null,
       _listingLifetime = listingLifetime {
    if (_platformRoots) {
      // Drives, volumes and iOS's Documents folder need the system.
      unawaited(refreshRoots());
    }
  }

  final FsPathResolver resolver;
  final bool _platformRoots;
  final Duration _listingLifetime;
  Future<void>? _refreshing;

  /// Reads this device's roots again (a USB stick came or went). Only for
  /// the platform's own roots, not ones a caller passed in.
  Future<void> refreshRoots() {
    if (!_platformRoots) {
      return Future.value();
    }
    return _refreshing ??= () async {
      try {
        resolver.setRoots(await platformFsRoots());
      } catch (_) {
        // Keep the roots we had.
      } finally {
        _refreshing = null;
      }
    }();
  }

  final _listings = <String, ({DateTime at, List<FsEntry> entries})>{};

  static const int pageSize = 500;

  /// Folders never listed: other devices' files mounted here, which this
  /// device would otherwise serve back to them and browse round in.
  static Set<String> Function() excluded = () => const {};

  Future<FsPage> list(
    String rootId,
    String relative, {
    int offset = 0,
    int limit = pageSize,
    bool showHidden = false,
  }) async {
    final key = '$rootId\u0000$relative\u0000$showHidden';
    final cached = _listings[key];
    List<FsEntry> entries;
    if (offset > 0 &&
        cached != null &&
        DateTime.now().difference(cached.at) < _listingLifetime) {
      entries = cached.entries;
    } else {
      entries = await _read(rootId, relative, showHidden: showHidden);
      _listings[key] = (at: DateTime.now(), entries: entries);
      if (_listings.length > 64) {
        _listings.remove(_listings.keys.first);
      }
    }
    final start = offset.clamp(0, entries.length);
    final end = (start + limit.clamp(1, pageSize)).clamp(0, entries.length);
    return FsPage(
      entries: entries.sublist(start, end),
      total: entries.length,
      offset: start,
    );
  }

  Future<List<FsEntry>> _read(
    String rootId,
    String relative, {
    required bool showHidden,
  }) async {
    final folder = await resolver.resolveExisting(rootId, relative);
    final dir = Directory(folder);
    if (!await dir.exists()) {
      throw const FsPathException('not a folder');
    }
    final entries = <FsEntry>[];
    final skip = {
      for (final path in excluded())
        Platform.isWindows ? path.toLowerCase() : path,
    };
    await for (final entity in dir.list(followLinks: false)) {
      if (skip.isNotEmpty &&
          skip.contains(
            Platform.isWindows ? entity.path.toLowerCase() : entity.path,
          )) {
        continue;
      }
      final name = p.basename(entity.path);
      if (FsUploads.isTemp(name)) {
        // A file being written from another device, not done yet.
        continue;
      }
      final hidden =
          name.startsWith('.') ||
          (Platform.isWindows && FsPlatform.isHiddenWindows(entity.path));
      if (hidden && !showHidden) {
        continue;
      }
      try {
        final isLink = entity is Link;
        // Follow links for type and size, but only within the root.
        var isDir = entity is Directory;
        var stat = await entity.stat();
        if (isLink) {
          final target = await entity.resolveSymbolicLinks();
          final base = await Directory(
            resolver.rootOf(rootId).directory,
          ).resolveSymbolicLinks();
          if (!FsPathResolver.isInside(base, target)) {
            continue;
          }
          stat = await FileStat.stat(target);
          isDir = stat.type == FileSystemEntityType.directory;
        }
        entries.add(
          FsEntry(
            name: name,
            isDir: isDir,
            size: isDir ? 0 : stat.size,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            hidden: hidden,
            isLink: isLink,
          ),
        );
      } on FileSystemException {
        // Unreadable entries (permissions, races) are skipped.
      }
    }
    entries.sort(compareEntries);
    return entries;
  }

  static int compareEntries(FsEntry a, FsEntry b) {
    if (a.isDir != b.isDir) {
      return a.isDir ? -1 : 1;
    }
    return naturalCompare(a.name, b.name);
  }

  /// Case-insensitive, with digit runs compared as numbers.
  static int naturalCompare(String a, String b) {
    final x = a.toLowerCase();
    final y = b.toLowerCase();
    var i = 0;
    var j = 0;
    while (i < x.length && j < y.length) {
      final cx = x.codeUnitAt(i);
      final cy = y.codeUnitAt(j);
      final dx = cx >= 48 && cx <= 57;
      final dy = cy >= 48 && cy <= 57;
      if (dx && dy) {
        var ei = i;
        while (ei < x.length &&
            x.codeUnitAt(ei) >= 48 &&
            x.codeUnitAt(ei) <= 57) {
          ei++;
        }
        var ej = j;
        while (ej < y.length &&
            y.codeUnitAt(ej) >= 48 &&
            y.codeUnitAt(ej) <= 57) {
          ej++;
        }
        final nx = x.substring(i, ei).replaceFirst(RegExp(r'^0+(?=.)'), '');
        final ny = y.substring(j, ej).replaceFirst(RegExp(r'^0+(?=.)'), '');
        if (nx.length != ny.length) {
          return nx.length - ny.length;
        }
        final c = nx.compareTo(ny);
        if (c != 0) {
          return c;
        }
        i = ei;
        j = ej;
        continue;
      }
      if (cx != cy) {
        return cx - cy;
      }
      i++;
      j++;
    }
    final rest = (x.length - i) - (y.length - j);
    return rest != 0 ? rest : a.compareTo(b);
  }

  Future<FsEntry> stat(String rootId, String relative) async {
    final real = await resolver.resolveExisting(rootId, relative);
    final stat = await FileStat.stat(real);
    final isDir = stat.type == FileSystemEntityType.directory;
    return FsEntry(
      name: p.basename(real),
      isDir: isDir,
      size: isDir ? 0 : stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  Future<String> mkdir(String rootId, String parent, String name) async {
    final target = await resolver.resolveNewChild(rootId, parent, name);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FsPathException('exists');
    }
    await Directory(target).create();
    invalidate(rootId);
    return resolver.relativeOf(rootId, target);
  }

  /// A new empty file [name] in [parent].
  Future<FsEntry> create(String rootId, String parent, String name) async {
    final target = await resolver.resolveNewChild(rootId, parent, name);
    try {
      await File(target).create(exclusive: true);
    } on FileSystemException {
      if (await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FsPathException('exists');
      }
      rethrow;
    }
    invalidate(rootId);
    return stat(rootId, await resolver.relativeOf(rootId, target));
  }

  /// Moves [relative] to [name] in [parent], within its root, replacing
  /// what is there the way a rename does: a file replaces a file, a
  /// folder an empty folder. Returns its new path.
  Future<String> move(
    String rootId,
    String relative,
    String parent,
    String name,
  ) async {
    final real = await resolver.resolveEntry(rootId, relative);
    final target = await resolver.resolveNewChild(rootId, parent, name);
    final type = await FileSystemEntity.type(real, followLinks: false);
    if (type == FileSystemEntityType.directory &&
        FsPathResolver.isInside(real, target)) {
      throw const FsPathException('into itself');
    }
    final there = await FileSystemEntity.type(target, followLinks: false);
    // The same entry under another case of its name ("a.txt" → "A.txt")
    // on a system that does not tell them apart.
    final same =
        there != FileSystemEntityType.notFound &&
        await FileSystemEntity.identical(real, target);
    if (!same && there == FileSystemEntityType.directory) {
      if (type != FileSystemEntityType.directory) {
        throw const FsPathException('exists');
      }
      if (!await Directory(target).list().isEmpty) {
        throw const FsPathException('not empty');
      }
      await Directory(target).delete();
    } else if (!same &&
        there != FileSystemEntityType.notFound &&
        type == FileSystemEntityType.directory) {
      throw const FsPathException('exists');
    }
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(real).rename(target);
      case FileSystemEntityType.link:
        await Link(real).rename(target);
      default:
        await File(real).rename(target);
    }
    invalidate(rootId);
    // Galleries follow a picture moved on a phone.
    await FsPlatform.mediaScan([real, target]);
    return resolver.relativeOf(rootId, target);
  }

  /// Sets a file's modification time (folders keep theirs).
  Future<void> touch(String rootId, String relative, int modifiedMs) async {
    final real = await resolver.resolveExisting(rootId, relative);
    if (await FileSystemEntity.type(real) == FileSystemEntityType.file) {
      await File(
        real,
      ).setLastModified(DateTime.fromMillisecondsSinceEpoch(modifiedMs));
      invalidate(rootId);
    }
  }

  /// Removes an empty folder; one with something in it stays.
  Future<void> removeFolder(String rootId, String relative) async {
    final real = await resolver.resolveEntry(rootId, relative);
    if (await FileSystemEntity.type(real, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FsPathException('not a folder');
    }
    if (!await Directory(real).list().isEmpty) {
      throw const FsPathException('not empty');
    }
    await Directory(real).delete();
    invalidate(rootId);
  }

  Future<String> rename(String rootId, String relative, String newName) async {
    FsPathResolver.checkName(newName);
    final real = await resolver.resolveEntry(rootId, relative);
    final target = p.join(p.dirname(real), newName);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FsPathException('exists');
    }
    final type = await FileSystemEntity.type(real, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(real).rename(target);
      case FileSystemEntityType.link:
        await Link(real).rename(target);
      default:
        await File(real).rename(target);
    }
    invalidate(rootId);
    return '${p.posix.dirname(relative) == '.' ? '' : '${p.posix.dirname(relative)}/'}$newName';
  }

  /// Deletes for good. Callers prefer [FsTrash] and use this only where
  /// the platform has no trash (Android), after the user confirmed.
  Future<void> deletePermanently(String rootId, String relative) async {
    final real = await resolver.resolveEntry(rootId, relative);
    final type = await FileSystemEntity.type(real, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(real).delete(recursive: true);
      case FileSystemEntityType.link:
        await Link(real).delete();
      default:
        await File(real).delete();
    }
    invalidate(rootId);
    await FsPlatform.mediaScan([real]);
  }

  /// Something in [rootId] changed: listings of it are read again.
  void invalidate(String rootId) {
    _listings.removeWhere((key, _) => key.startsWith('$rootId\u0000'));
  }
}
