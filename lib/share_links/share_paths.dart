import 'dart:io';

import 'package:path/path.dart' as p;

import 'share_hidden.dart';
import 'share_link.dart';
import 'share_zip.dart';

/// A request path that is not acceptable (encoded slashes, `..`, NUL…).
class SharePathException implements Exception {
  const SharePathException(this.reason);

  final String reason;

  @override
  String toString() => 'SharePathException($reason)';
}

/// Splits the still percent-encoded path of a request into decoded
/// segments. A trailing slash is dropped; anything that could name a
/// different place once decoded is refused.
List<String> shareRequestSegments(String encodedPath, {bool? windows}) {
  final onWindows = windows ?? Platform.isWindows;
  if (!encodedPath.startsWith('/')) {
    throw const SharePathException('relative');
  }
  var path = encodedPath.substring(1);
  if (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) {
    return const [];
  }
  final segments = <String>[];
  for (final raw in path.split('/')) {
    final String segment;
    try {
      segment = Uri.decodeComponent(raw);
    } on ArgumentError {
      throw const SharePathException('encoding');
    } on FormatException {
      throw const SharePathException('encoding');
    }
    checkShareSegment(segment, windows: onWindows);
    segments.add(segment);
  }
  return segments;
}

final _windowsDevice = RegExp(
  r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³]|conin\$|conout\$)(\..*)?$',
  caseSensitive: false,
);

/// One decoded path segment: a plain name, nothing that climbs or
/// reaches somewhere else.
void checkShareSegment(String segment, {bool? windows}) {
  final onWindows = windows ?? Platform.isWindows;
  if (segment.isEmpty ||
      segment == '.' ||
      segment == '..' ||
      segment.contains('/') ||
      segment.contains('\\') ||
      segment.contains('\u0000')) {
    throw const SharePathException('segment');
  }
  for (final unit in segment.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) {
      throw const SharePathException('control');
    }
  }
  if (onWindows) {
    // Drive letters, alternate data streams, device names, and the
    // trailing dots and spaces Windows quietly strips.
    if (segment.contains(':') ||
        segment.contains('*') ||
        segment.contains('?') ||
        segment.contains('"') ||
        segment.contains('<') ||
        segment.contains('>') ||
        segment.contains('|') ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        _windowsDevice.hasMatch(segment)) {
      throw const SharePathException('windows');
    }
  }
}

/// Names Finder, Explorer and Linux file managers keep out of sight; they
/// are not listed, zipped or served from inside a shared folder.
bool isShareHiddenName(String name) =>
    name.startsWith('.') ||
    name == 'Thumbs.db' ||
    name == 'desktop.ini' ||
    name == r'$RECYCLE.BIN' ||
    name == 'System Volume Information';

/// What a path inside a link points at.
class ShareTarget {
  const ShareTarget({
    required this.item,
    required this.realPath,
    required this.isDir,
    required this.size,
    required this.modified,
    required this.relative,
    required this.mode,
  });

  /// The link's item it is in (or is).
  final ShareItem item;

  /// Real path on disk, symlinks resolved.
  final String realPath;
  final bool isDir;
  final int size;
  final DateTime modified;
  final int mode;

  /// Segments from the link's first page: for one shared folder, inside
  /// it; otherwise starting with the item's name.
  final List<String> relative;

  String get name => relative.isEmpty ? item.name : relative.last;
}

/// One row of a folder page.
class ShareListing {
  const ShareListing({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
  });

  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;
}

/// Maps request paths onto a link's items and the disk, refusing anything
/// that would leave what was shared (`..`, symlinks that point outside).
class ShareResolver {
  const ShareResolver();

  /// The real path of [item] itself, or null when it is gone.
  Future<String?> itemRoot(ShareItem item) async {
    try {
      final type = await FileSystemEntity.type(item.path);
      if (type == FileSystemEntityType.notFound ||
          (item.isDir != (type == FileSystemEntityType.directory))) {
        return null;
      }
      return item.isDir
          ? await Directory(item.path).resolveSymbolicLinks()
          : await File(item.path).resolveSymbolicLinks();
    } on FileSystemException {
      return null;
    }
  }

  /// [relative] segments of [link] (see [ShareTarget.relative]); null for
  /// anything missing, hidden or outside. An empty list on a link that is
  /// not a single folder is its list of items, which has no target.
  Future<ShareTarget?> resolve(ShareLink link, List<String> relative) async {
    final ShareItem item;
    final List<String> inside;
    if (link.isSingleFolder) {
      item = link.items.first;
      inside = relative;
    } else {
      if (relative.isEmpty) {
        return null;
      }
      final match = link.items.where((i) => i.name == relative.first);
      if (match.isEmpty) {
        return null;
      }
      item = match.first;
      inside = relative.sublist(1);
    }
    if (!item.isDir && inside.isNotEmpty) {
      return null;
    }
    if (inside.any(isShareHiddenName)) {
      return null;
    }
    final base = await itemRoot(item);
    if (base == null) {
      return null;
    }
    final joined = inside.isEmpty ? base : p.joinAll([base, ...inside]);
    try {
      final type = await FileSystemEntity.type(joined);
      if (type == FileSystemEntityType.notFound) {
        return null;
      }
      final isDir = type == FileSystemEntityType.directory;
      final real = isDir
          ? await Directory(joined).resolveSymbolicLinks()
          : await File(joined).resolveSymbolicLinks();
      // Checked on the real path, not the request: a Windows short name
      // (SSH~1) or a symlink inside the folder can name a hidden item.
      if (!isShareVisibleInside(base, real)) {
        return null;
      }
      final stat = await FileStat.stat(real);
      if (stat.type == FileSystemEntityType.notFound) {
        return null;
      }
      return ShareTarget(
        item: item,
        realPath: real,
        isDir: stat.type == FileSystemEntityType.directory,
        size: stat.type == FileSystemEntityType.directory ? 0 : stat.size,
        modified: stat.modified,
        mode: stat.mode,
        relative: relative,
      );
    } on FileSystemException {
      return null;
    }
  }

  /// The visible contents of a folder [target], symlinks only when they
  /// stay inside the shared item. Folders first, then by name.
  Future<List<ShareListing>> list(ShareTarget target) async {
    final base = await itemRoot(target.item);
    if (base == null) {
      return const [];
    }
    final out = <ShareListing>[];
    try {
      await for (final entity in Directory(
        target.realPath,
      ).list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (isShareHiddenName(name)) {
          continue;
        }
        final listing = await _describe(entity, base, name);
        if (listing != null) {
          out.add(listing);
        }
      }
    } on FileSystemException {
      // A folder that cannot be read shows as empty rather than failing.
    }
    out.sort(compareShareListings);
    return out;
  }

  /// The link's own items, for its first page when it is not one folder;
  /// the ones that are gone are left out.
  Future<List<ShareListing>> listItems(ShareLink link) async {
    final out = <ShareListing>[];
    for (final item in link.items) {
      final real = await itemRoot(item);
      if (real == null) {
        continue;
      }
      try {
        final stat = await FileStat.stat(real);
        out.add(
          ShareListing(
            name: item.name,
            isDir: item.isDir,
            size: item.isDir ? 0 : stat.size,
            modified: stat.modified,
          ),
        );
      } on FileSystemException {
        continue;
      }
    }
    out.sort(compareShareListings);
    return out;
  }

  Future<ShareListing?> _describe(
    FileSystemEntity entity,
    String base,
    String name,
  ) async {
    try {
      var path = entity.path;
      if (entity is Link) {
        final real = await entity.resolveSymbolicLinks();
        if (!isShareVisibleInside(base, real)) {
          return null;
        }
        path = real;
      } else if (shareHiddenFlag(path)) {
        return null;
      }
      final stat = await FileStat.stat(path);
      return switch (stat.type) {
        FileSystemEntityType.directory => ShareListing(
          name: name,
          isDir: true,
          size: 0,
          modified: stat.modified,
        ),
        FileSystemEntityType.file => ShareListing(
          name: name,
          isDir: false,
          size: stat.size,
          modified: stat.modified,
        ),
        _ => null,
      };
    } on FileSystemException {
      return null;
    }
  }

  /// Everything under [target] (a folder, or the whole link when null) as
  /// zip entries, walked afresh (and in the same order) each time the
  /// source is called, so a huge tree is never held in memory. Symlinked
  /// files are followed when they stay inside and visible; symlinked
  /// folders are skipped (no loops). Hidden items are left out.
  ShareZipSource zipSource(ShareLink link, {ShareTarget? target}) =>
      () => _zip(link, target);

  Stream<ShareZipEntry> _zip(ShareLink link, ShareTarget? target) async* {
    if (target != null) {
      final base = await itemRoot(target.item);
      if (base == null) {
        return;
      }
      final top = shareZipSegment(target.name);
      yield ShareZipEntry.folder('$top/', target.modified);
      yield* _walk(target.realPath, '$top/', base);
      return;
    }
    for (final item in link.items) {
      final real = await itemRoot(item);
      if (real == null) {
        continue;
      }
      final FileStat stat;
      try {
        stat = await FileStat.stat(real);
      } on FileSystemException {
        continue;
      }
      final top = shareZipSegment(item.name);
      if (item.isDir) {
        yield ShareZipEntry.folder('$top/', stat.modified);
        yield* _walk(real, '$top/', real);
      } else {
        yield ShareZipEntry.file(
          top,
          real,
          stat.size,
          stat.modified,
          mode: _fileMode(stat.mode),
        );
      }
    }
  }

  Stream<ShareZipEntry> _walk(
    String folder,
    String prefix,
    String base,
  ) async* {
    final children = <FileSystemEntity>[];
    try {
      await for (final entity in Directory(folder).list(followLinks: false)) {
        children.add(entity);
      }
    } on FileSystemException {
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final entity in children) {
      final name = p.basename(entity.path);
      if (isShareHiddenName(name)) {
        continue;
      }
      final entry = '$prefix${shareZipSegment(name)}';
      String? path;
      FileStat? stat;
      try {
        if (entity is Link) {
          final real = await entity.resolveSymbolicLinks();
          if (!isShareVisibleInside(base, real)) {
            continue;
          }
          final target = await FileStat.stat(real);
          if (target.type == FileSystemEntityType.file) {
            path = real;
            stat = target;
          }
        } else if (!shareHiddenFlag(entity.path)) {
          path = entity.path;
          stat = await FileStat.stat(entity.path);
        }
      } on FileSystemException {
        continue;
      }
      if (path == null || stat == null) {
        continue;
      }
      if (stat.type == FileSystemEntityType.directory && entity is! Link) {
        yield ShareZipEntry.folder('$entry/', stat.modified);
        yield* _walk(path, '$entry/', base);
      } else if (stat.type == FileSystemEntityType.file) {
        yield ShareZipEntry.file(
          entry,
          path,
          stat.size,
          stat.modified,
          mode: _fileMode(stat.mode),
        );
      }
    }
  }
}

int _fileMode(int statMode) {
  if (Platform.isWindows) {
    return 0x81A4;
  }
  // Keep the permission bits (an executable stays executable), always as
  // a regular file readable by its owner.
  return 0x8000 | (statMode & 0x1FF) | 0x100;
}

/// [path] is [base] or inside it (case-insensitively on Windows).
bool isShareInside(String base, String path) =>
    p.equals(base, path) || p.isWithin(base, path);

/// [real] (symlinks resolved) is inside [base] and nothing on the way
/// down from [base] is hidden, by name or by the file system's flag.
bool isShareVisibleInside(String base, String real) {
  if (!isShareInside(base, real)) {
    return false;
  }
  if (p.equals(base, real)) {
    return true;
  }
  var path = base;
  for (final part in p.split(p.relative(real, from: base))) {
    if (part == '.' || part.isEmpty) {
      continue;
    }
    if (isShareHiddenName(part)) {
      return false;
    }
    path = p.join(path, part);
    if (shareHiddenFlag(path)) {
      return false;
    }
  }
  return true;
}

/// Folders first, then names in natural order ("2" before "10").
int compareShareListings(ShareListing a, ShareListing b) {
  if (a.isDir != b.isDir) {
    return a.isDir ? -1 : 1;
  }
  return compareShareNames(a.name, b.name);
}

final _chunks = RegExp(r'\d+|\D+');

int compareShareNames(String a, String b) {
  final x = _chunks.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final y = _chunks.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final m = x[i];
    final n = y[i];
    final mi = int.tryParse(m.length > 15 ? '' : m);
    final ni = int.tryParse(n.length > 15 ? '' : n);
    final c = (mi != null && ni != null) ? mi.compareTo(ni) : m.compareTo(n);
    if (c != 0) {
      return c;
    }
  }
  final c = x.length.compareTo(y.length);
  return c != 0 ? c : a.compareTo(b);
}
