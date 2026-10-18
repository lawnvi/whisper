import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'fs_platform.dart';

/// A place another device may browse: the home folder on desktops, shared
/// storage on Android, the app's Documents on iOS, Windows drives and Linux
/// mounted volumes, plus well-known folders inside it as shortcuts.
class FsRoot {
  const FsRoot({
    required this.id,
    required this.directory,
    this.shortcuts = const [],
    this.kind = FsRootKind.home,
    this.label = '',
    this.drive = '',
    this.removable = false,
  });

  /// Stable id used on the wire instead of an absolute path.
  final String id;
  final String directory;

  /// Well-known folders under [directory], as paths relative to it.
  final List<FsShortcut> shortcuts;

  /// What it is, for its name and icon on the browsing side.
  final FsRootKind kind;

  /// The volume's own name ("Data", "KINGSTON"), when it has one.
  final String label;

  /// Windows drive letter ("C"), for drives.
  final String drive;

  /// A USB stick or card rather than a built-in disk.
  final bool removable;

  /// Wire description (without shortcuts, which the host checks first).
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    if (label.isNotEmpty) 'name': label,
    if (drive.isNotEmpty) 'drive': drive,
    if (removable) 'removable': true,
  };
}

enum FsRootKind {
  /// The user's home folder (desktops).
  home,

  /// Android shared storage.
  storage,

  /// The app's own Documents folder (iOS: "On My iPhone › Whisper").
  documents,

  /// A Windows drive (C:, D:…).
  drive,

  /// A mounted volume on Linux (/media/‹user›/…, /run/media/‹user›/…).
  volume,
}

class FsShortcut {
  const FsShortcut({required this.kind, required this.path});

  /// desktop, documents, downloads, pictures, camera, movies, music.
  final String kind;

  /// Relative to the root, '/'-separated.
  final String path;
}

/// Raised when a requested path is not allowed (outside the root, through
/// a symlink that leaves it, malformed). Never says why in detail on the
/// wire.
class FsPathException implements Exception {
  const FsPathException(this.reason);

  final String reason;

  @override
  String toString() => 'FsPathException($reason)';
}

/// The roots this device offers, by platform, as far as they are known
/// without asking the system (see [platformFsRoots] for drives, volumes and
/// iOS's Documents folder).
List<FsRoot> defaultFsRoots() {
  if (Platform.isAndroid) {
    const storage = '/storage/emulated/0';
    return const [
      FsRoot(
        id: 'storage',
        directory: storage,
        kind: FsRootKind.storage,
        shortcuts: [
          FsShortcut(kind: 'downloads', path: 'Download'),
          FsShortcut(kind: 'camera', path: 'DCIM/Camera'),
          FsShortcut(kind: 'pictures', path: 'Pictures'),
          FsShortcut(kind: 'documents', path: 'Documents'),
          FsShortcut(kind: 'movies', path: 'Movies'),
          FsShortcut(kind: 'music', path: 'Music'),
        ],
      ),
    ];
  }
  final home =
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  if (home == null || home.isEmpty) {
    return const [];
  }
  if (Platform.isIOS) {
    // The app's sandbox: what other devices put here shows in Files under
    // "On My iPhone › Whisper".
    return [
      FsRoot(
        id: 'documents',
        directory: p.join(home, 'Documents'),
        kind: FsRootKind.documents,
      ),
    ];
  }
  return [
    FsRoot(
      id: 'home',
      directory: home,
      shortcuts: Platform.isLinux
          ? linuxUserDirShortcuts(home, _readXdgUserDirs(home))
          : _homeShortcuts(movies: Platform.isMacOS ? 'Movies' : 'Videos'),
    ),
  ];
}

List<FsShortcut> _homeShortcuts({required String movies}) => [
  const FsShortcut(kind: 'desktop', path: 'Desktop'),
  const FsShortcut(kind: 'documents', path: 'Documents'),
  const FsShortcut(kind: 'downloads', path: 'Downloads'),
  const FsShortcut(kind: 'pictures', path: 'Pictures'),
  FsShortcut(kind: 'movies', path: movies),
  const FsShortcut(kind: 'music', path: 'Music'),
];

/// Every root this device offers now: [defaultFsRoots] plus what only the
/// system can tell (Windows drives, Linux mounted volumes, the real iOS
/// Documents folder). Drives and volumes come and go; call it again when
/// someone starts browsing.
Future<List<FsRoot>> platformFsRoots() async {
  final roots = defaultFsRoots();
  if (Platform.isIOS) {
    try {
      final documents = await getApplicationDocumentsDirectory();
      return [
        FsRoot(
          id: 'documents',
          directory: documents.path,
          kind: FsRootKind.documents,
        ),
      ];
    } catch (_) {
      return roots;
    }
  }
  if (Platform.isWindows) {
    return [...roots, ...await FsPlatform.windowsDrives()];
  }
  if (Platform.isLinux) {
    final user =
        Platform.environment['USER'] ?? Platform.environment['LOGNAME'] ?? '';
    try {
      final mounts = await File('/proc/self/mounts').readAsString();
      return [...roots, ...linuxVolumeRoots(mounts, user)];
    } catch (_) {
      return roots;
    }
  }
  return roots;
}

/// Windows drive roots, from what `GetLogicalDrives` and friends say.
FsRoot windowsDriveRoot({
  required String letter,
  required String label,
  bool removable = false,
}) {
  final upper = letter.toUpperCase();
  return FsRoot(
    id: 'drive:${upper.toLowerCase()}',
    directory: '$upper:\\',
    kind: FsRootKind.drive,
    label: label,
    drive: upper,
    removable: removable,
  );
}

String? _readXdgUserDirs(String home) {
  final config =
      Platform.environment['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
  try {
    return File(p.join(config, 'user-dirs.dirs')).readAsStringSync();
  } catch (_) {
    return null;
  }
}

/// Shortcuts for a Linux home: the XDG user folders as the desktop names
/// them (`~/.config/user-dirs.dirs`, localized: "桌面", "下载"…), else the
/// English defaults. Folders outside the home or equal to it are left out.
List<FsShortcut> linuxUserDirShortcuts(String home, String? userDirs) {
  const keys = {
    'desktop': 'XDG_DESKTOP_DIR',
    'documents': 'XDG_DOCUMENTS_DIR',
    'downloads': 'XDG_DOWNLOAD_DIR',
    'pictures': 'XDG_PICTURES_DIR',
    'movies': 'XDG_VIDEOS_DIR',
    'music': 'XDG_MUSIC_DIR',
  };
  final defaults = {
    for (final shortcut in _homeShortcuts(movies: 'Videos'))
      shortcut.kind: shortcut.path,
  };
  final configured = <String, String>{};
  for (final line in const LineSplitter().convert(userDirs ?? '')) {
    final match = RegExp(
      r'^\s*(XDG_[A-Z]+_DIR)\s*=\s*"((?:[^"\\]|\\.)*)"\s*$',
    ).firstMatch(line);
    if (match == null) {
      continue;
    }
    var value = match
        .group(2)!
        .replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);
    if (value.startsWith(r'$HOME')) {
      value = home + value.substring(5);
    } else if (!value.startsWith('/')) {
      continue;
    }
    configured[match.group(1)!] = p.normalize(value);
  }
  final shortcuts = <FsShortcut>[];
  for (final MapEntry(key: kind, value: key) in keys.entries) {
    final path = configured[key];
    if (path == null) {
      shortcuts.add(FsShortcut(kind: kind, path: defaults[kind]!));
    } else if (path != p.normalize(home) && p.isWithin(home, path)) {
      shortcuts.add(
        FsShortcut(
          kind: kind,
          path: p.split(p.relative(path, from: home)).join('/'),
        ),
      );
    }
  }
  return shortcuts;
}

/// Volumes mounted for [user] under /media/‹user› or /run/media/‹user›
/// (udisks), from the text of /proc/self/mounts.
List<FsRoot> linuxVolumeRoots(String mounts, String user) {
  if (user.isEmpty) {
    return const [];
  }
  final bases = ['/media/$user/', '/run/media/$user/'];
  final roots = <FsRoot>[];
  final ids = <String>{};
  for (final line in const LineSplitter().convert(mounts)) {
    final fields = line.split(' ');
    if (fields.length < 3) {
      continue;
    }
    // Spaces and other bytes in mount points are octal escapes (\040).
    final point = fields[1].replaceAllMapped(
      RegExp(r'\\([0-7]{3})'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 8)),
    );
    final base = bases.where(point.startsWith).firstOrNull;
    if (base == null) {
      continue;
    }
    final name = point.substring(base.length);
    if (name.isEmpty || name.contains('/')) {
      continue;
    }
    var id = 'vol:$name';
    for (var n = 2; !ids.add(id); n++) {
      id = 'vol:$name $n';
    }
    roots.add(
      FsRoot(
        id: id,
        directory: point,
        kind: FsRootKind.volume,
        label: name,
        removable: true,
      ),
    );
  }
  return roots;
}

/// Maps wire paths (root id + relative path) to real paths and back, and
/// refuses anything that would leave the root.
class FsPathResolver {
  FsPathResolver(List<FsRoot> roots, {bool? windows})
    : _roots = {for (final root in roots) root.id: root},
      _windows = windows ?? Platform.isWindows;

  final Map<String, FsRoot> _roots;
  final _canonicalRoots = <String, String>{};

  /// Apply Windows name rules (reserved device names, `:`, trailing dots).
  final bool _windows;

  Iterable<FsRoot> get roots => _roots.values;

  /// Drives or volumes came or went: later lookups use [roots].
  void setRoots(List<FsRoot> roots) {
    final next = {for (final root in roots) root.id: root};
    for (final MapEntry(key: id, value: root) in next.entries) {
      if (_roots[id]?.directory != root.directory) {
        _canonicalRoots.remove(id);
      }
    }
    _canonicalRoots.removeWhere((id, _) => !next.containsKey(id));
    _roots
      ..clear()
      ..addAll(next);
  }

  FsRoot rootOf(String id) {
    final root = _roots[id];
    if (root == null) {
      throw const FsPathException('unknown root');
    }
    return root;
  }

  /// Checks the shape of a relative wire path: '/'-separated, no empty,
  /// '.' or '..' segments, no NUL, not absolute. On Windows every segment
  /// must also be a valid name: no `:` (drives, alternate data streams), no
  /// device names (CON, NUL, COM1…) and no trailing dot or space, which
  /// Windows would quietly strip.
  static List<String> segments(String relative, {bool? windows}) {
    if (relative.isEmpty) {
      return const [];
    }
    if (relative.contains('\u0000') ||
        relative.startsWith('/') ||
        relative.contains('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(relative)) {
      throw const FsPathException('malformed');
    }
    final parts = relative.split('/');
    final strict = windows ?? Platform.isWindows;
    for (final part in parts) {
      if (part.isEmpty || part == '.' || part == '..') {
        throw const FsPathException('malformed');
      }
      if (strict && fsNameProblem(part, windows: true) != null) {
        throw const FsPathException('malformed');
      }
    }
    return parts;
  }

  /// A single file or folder name for create and rename.
  static void checkName(String name, {bool? windows}) {
    if (fsNameProblem(name, windows: windows ?? Platform.isWindows) != null) {
      throw const FsPathException('bad name');
    }
  }

  List<String> _segments(String relative) =>
      segments(relative, windows: _windows);

  Future<String> _canonicalRoot(FsRoot root) async {
    final cached = _canonicalRoots[root.id];
    if (cached != null) {
      return cached;
    }
    final resolved = await Directory(root.directory).resolveSymbolicLinks();
    return _canonicalRoots[root.id] = resolved;
  }

  /// The real path for an existing entry, after following symlinks, which
  /// must still be inside the root.
  Future<String> resolveExisting(String rootId, String relative) async {
    final root = rootOf(rootId);
    final base = await _canonicalRoot(root);
    final joined = p.joinAll([base, ..._segments(relative)]);
    final type = await FileSystemEntity.type(joined, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw const FsPathException('not found');
    }
    final real = type == FileSystemEntityType.link
        ? await Link(joined).resolveSymbolicLinks()
        : await (type == FileSystemEntityType.directory
              ? Directory(joined).resolveSymbolicLinks()
              : File(joined).resolveSymbolicLinks());
    if (!isInside(base, real)) {
      throw const FsPathException('outside root');
    }
    return real;
  }

  /// The entry itself (a symlink stays a symlink, so renaming or deleting
  /// it never touches what it points to); its folder must resolve inside
  /// the root. The root itself is refused.
  Future<String> resolveEntry(String rootId, String relative) async {
    final parts = _segments(relative);
    if (parts.isEmpty) {
      throw const FsPathException('root');
    }
    final folder = await resolveExisting(
      rootId,
      parts.sublist(0, parts.length - 1).join('/'),
    );
    final path = p.join(folder, parts.last);
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      throw const FsPathException('not found');
    }
    return path;
  }

  /// The real path for a new child [name] of an existing folder.
  Future<String> resolveNewChild(
    String rootId,
    String parent,
    String name,
  ) async {
    checkName(name, windows: _windows);
    final folder = await resolveExisting(rootId, parent);
    if (await FileSystemEntity.type(folder) != FileSystemEntityType.directory) {
      throw const FsPathException('not a folder');
    }
    return p.join(folder, name);
  }

  /// [real] relative to the root, '/'-separated, for the wire.
  Future<String> relativeOf(String rootId, String real) async {
    final base = await _canonicalRoot(rootOf(rootId));
    if (!isInside(base, real)) {
      throw const FsPathException('outside root');
    }
    return p
        .split(p.relative(real, from: base))
        .where((part) => part != '.')
        .join('/');
  }

  static bool isInside(String base, String path) =>
      path == base || p.isWithin(base, path);
}

/// Why [name] can't be a file or folder name here, or null when it can:
/// `empty`, `tooLong`, `dots` ('.', '..'), `separator`, `control`, and on
/// Windows also `character` (one of <>:"|?*), `reserved` (CON, PRN, AUX,
/// NUL, COM1–9, LPT1–9, with or without an extension) and `trailing` (a
/// trailing dot or space).
String? fsNameProblem(String name, {required bool windows}) {
  if (name.isEmpty) {
    return 'empty';
  }
  if (name.length > 255) {
    return 'tooLong';
  }
  if (name == '.' || name == '..') {
    return 'dots';
  }
  if (name.contains('/') || name.contains('\\')) {
    return 'separator';
  }
  if (name.contains('\u0000')) {
    return 'control';
  }
  if (!windows) {
    return null;
  }
  for (final unit in name.codeUnits) {
    if (unit < 0x20) {
      return 'control';
    }
  }
  if (RegExp(r'[<>:"|?*]').hasMatch(name)) {
    return 'character';
  }
  if (name.endsWith('.') || name.endsWith(' ')) {
    return 'trailing';
  }
  // "con.txt" and "NUL.tar.gz" are the device too; so are the superscript
  // COM¹–³ and LPT¹–³ that Windows also reserves.
  final stem = name.split('.').first.trimRight().toUpperCase();
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|(COM|LPT)[1-9\u00b9\u00b2\u00b3])$',
  ).hasMatch(stem)) {
    return 'reserved';
  }
  return null;
}
