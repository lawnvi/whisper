import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fs_paths.dart';
import 'fs_platform.dart';

/// One of the folders a computer's user keeps things in (desktop,
/// documents, downloads, pictures, movies, music), where it is now.
class FsCommonFolder {
  const FsCommonFolder({required this.kind, required this.path});

  final String kind;
  final String path;
}

const _commonKinds = [
  'desktop',
  'documents',
  'downloads',
  'pictures',
  'movies',
  'music',
];

/// The usual folders of [home] (`defaultFsRoots`' home) that exist, where
/// the system keeps them: Windows wherever they were moved (another drive,
/// OneDrive), Linux wherever `user-dirs.dirs` says, else in [home].
Future<List<FsCommonFolder>> fsCommonFolders(FsRoot? home) async {
  final moved = Platform.isWindows
      ? FsPlatform.windowsKnownFolders()
      : Platform.isLinux && home != null
      ? linuxUserDirs(home.directory, readXdgUserDirs(home.directory))
      : const <String, String>{};
  final inHome = {
    if (home != null)
      for (final shortcut in home.shortcuts)
        shortcut.kind: p.joinAll([home.directory, ...shortcut.path.split('/')]),
  };
  return [
    for (final kind in _commonKinds)
      if (moved[kind] ?? inHome[kind] case final path?)
        if (await Directory(path).exists())
          FsCommonFolder(kind: kind, path: path),
  ];
}

String _systemDriveLetter() =>
    (Platform.environment['SystemDrive'] ?? 'C:').substring(0, 1).toUpperCase();

/// This computer's disks and partitions other than the one the system and
/// the home folder are on, mounted now: Windows drives (`D:\`), volumes in
/// /Volumes, Linux partitions and USB sticks (`/mnt/data`,
/// `/media/‹user›/KINGSTON`).
Future<List<FsRoot>> fsOtherDisks() async {
  if (Platform.isWindows) {
    final system = _systemDriveLetter();
    return [
      for (final drive in await FsPlatform.windowsDrives())
        if (drive.drive != system) drive,
    ];
  }
  try {
    if (Platform.isMacOS) {
      final mount = await Process.run('/sbin/mount', const []);
      return volumeRoots(macOtherVolumes(mount.stdout as String));
    }
    if (Platform.isLinux) {
      final env = Platform.environment;
      return volumeRoots(
        linuxOtherDisks(
          await File('/proc/self/mounts').readAsString(),
          user: env['USER'] ?? env['LOGNAME'] ?? '',
          home: env['HOME'] ?? '',
        ),
      );
    }
  } catch (_) {
    // Nothing found.
  }
  return const [];
}

/// The volumes `mount` lists in /Volumes that the Finder shows: local, not
/// hidden (`nobrowse`, like Recovery). Network shares, and so other
/// devices' files Whisper mounts, are not local.
List<FsVolume> macOtherVolumes(String mountOutput) {
  final line = RegExp(r'^.+ on (/Volumes/.+) \(([^()]*)\)$');
  return [
    for (final text in const LineSplitter().convert(mountOutput))
      if (line.firstMatch(text) case final match?)
        if (match.group(2)!.split(', ') case final options
            when options.contains('local') && !options.contains('nobrowse'))
          (path: match.group(1)!, label: '', removable: true),
  ];
}

/// Partitions and drives in /proc/self/mounts ([mounts]) that hold the
/// user's things: what udisks mounts for [user] under /media or
/// /run/media, and any other block device mounted outside the system's
/// own folders and not holding [home] (a separate /home is the system's
/// side, like /). Snaps, containers and the like are not block devices or
/// are under those folders. Whisper's own mounts (FUSE, in ~/Whisper) are
/// neither.
List<FsVolume> linuxOtherDisks(
  String mounts, {
  required String user,
  required String home,
}) {
  const system = [
    '/bin', '/boot', '/dev', '/efi', '/etc', '/gnu', '/lib', '/lib32', //
    '/lib64', '/nix', '/opt', '/proc', '/root', '/run', '/sbin', '/snap',
    '/srv', '/sys', '/tmp', '/usr', '/var',
  ];
  final media = [
    if (user.isNotEmpty) ...['/media/$user', '/run/media/$user'],
  ];
  // Spaces and other bytes in mount points are octal escapes (\040).
  String unescape(String field) => field.replaceAllMapped(
    RegExp(r'\\([0-7]{3})'),
    (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 8)),
  );
  final found = <String, FsVolume>{};
  for (final line in const LineSplitter().convert(mounts)) {
    final fields = line.split(' ');
    if (fields.length < 3) {
      continue;
    }
    final source = unescape(fields[0]);
    final point = p.normalize(unescape(fields[1]));
    final onMedia = media.any((base) => p.isWithin(base, point));
    final block =
        (source.startsWith('/dev/') && !source.startsWith('/dev/loop')) ||
        fields[2] == 'zfs';
    if (!(onMedia || block) ||
        point == '/' ||
        (home.isNotEmpty &&
            (p.equals(point, home) || p.isWithin(point, home)))) {
      continue;
    }
    if (!onMedia &&
        system.any((dir) => point == dir || p.isWithin(dir, point))) {
      continue;
    }
    // The last mount on a folder is the one seen there.
    found[point] = (path: point, label: '', removable: onMedia);
  }
  return found.values.toList();
}

/// The disk the system runs from, shared as the home folder on it, never
/// as a root of its own: Windows' `%SystemDrive%` (C:\) with its label,
/// else `/`, named after the volume the Finder shows for it on macOS
/// ("Macintosh HD").
Future<FsRoot> fsSystemDisk() async {
  if (Platform.isWindows) {
    final letter = _systemDriveLetter();
    return (await FsPlatform.windowsDrives())
            .where((drive) => drive.drive == letter)
            .firstOrNull ??
        windowsDriveRoot(letter: letter, label: '');
  }
  var label = '';
  if (Platform.isMacOS) {
    try {
      await for (final entry in Directory(
        '/Volumes',
      ).list(followLinks: false)) {
        if (entry is Link && await entry.resolveSymbolicLinks() == '/') {
          label = p.basename(entry.path);
          break;
        }
      }
    } on FileSystemException {
      // Named as the system disk.
    }
  }
  return FsRoot(
    id: 'system',
    directory: '/',
    kind: FsRootKind.volume,
    label: label,
  );
}

/// What on a Windows disk is the system's or installed programs', which is
/// never shared, by name in lower case. Only the home folder of the system
/// disk is shared, so this is for the others (`D:\Program Files`).
const _windowsTopNames = {
  'windows', 'program files', 'program files (x86)', 'programdata', //
  'perflogs', 'recovery', 'windows.old', 'system volume information',
  'config.msi', 'msocache', 'boot', 'documents and settings',
  'onedrivetemp', 'inetpub',
};

/// The same in a home folder: installed apps (macOS), snaps' data (Linux).
/// Windows marks its own there (NTUSER.DAT, the old junctions).
const _systemHomeNames = {
  'macos': {'applications'},
  'linux': {'snap'},
};

/// The system's own folders and files in [roots] (the shared disks, real
/// paths), never shared whatever else is: Windows' and its programs' at the
/// top of a disk, what starts with a dot or `$` there or is marked as the
/// system's (recycle bins, System Volume Information), the other users'
/// folders beside [home] (a disk holding it), and installed apps in it. The
/// floor (`FsProtectedAreas`) adds keys, settings and app data.
Future<List<String>> fsSystemFolders({
  required List<String> roots,
  required String home,
  String? platform,
}) async {
  final os = platform ?? Platform.operatingSystem;
  final windows = os == 'windows';
  String fold(String name) =>
      windows || os == 'macos' ? name.toLowerCase() : name;
  final found = <String>[];
  Future<void> scan(
    String folder,
    bool Function(String name, String path) theirs,
  ) async {
    try {
      await for (final entry in Directory(folder).list(followLinks: false)) {
        if (theirs(p.basename(entry.path), entry.path)) {
          found.add(entry.path);
        }
      }
    } on FileSystemException {
      // Not there, or not ours to list.
    }
  }

  for (final root in roots) {
    if (p.equals(root, home)) {
      // Its own rules below: a folder named Boot in it is the user's.
      continue;
    }
    await scan(
      root,
      (name, path) =>
          name.startsWith('.') ||
          (windows && name.startsWith(r'$')) ||
          name == 'lost+found' ||
          (windows && _windowsTopNames.contains(name.toLowerCase())) ||
          FsPlatform.isSystemWindows(path),
    );
  }
  if (home.isNotEmpty &&
      roots.any((root) => p.equals(root, home) || p.isWithin(root, home))) {
    final users = p.dirname(home);
    if (roots.any((root) => p.isWithin(root, home) && !p.equals(root, home))) {
      await scan(
        users,
        (name, path) =>
            !p.equals(path, home) &&
            !const {'public', 'shared'}.contains(name.toLowerCase()),
      );
    }
    final names = _systemHomeNames[os] ?? const <String>{};
    await scan(
      home,
      (name, path) =>
          names.contains(fold(name)) || FsPlatform.isSystemWindows(path),
    );
  }
  return found;
}
