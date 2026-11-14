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

/// A disk or partition of this computer other than the system's, which
/// can be shared whole: a Windows drive (`D:\`), a volume in /Volumes, a
/// Linux partition or USB stick (`/mnt/data`, `/media/‹user›/KINGSTON`).
class FsDisk {
  const FsDisk({
    required this.path,
    this.label = '',
    this.drive = '',
    this.removable = false,
  });

  final String path;

  /// The volume's own name ("Data"); for a Linux mount, its folder's name.
  final String label;

  /// The Windows drive letter ("D").
  final String drive;
  final bool removable;
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

/// This computer's disks and partitions other than the one the system and
/// the home folder are on, mounted now. [excluded] are other devices'
/// files mounted here, which are never shared.
Future<List<FsDisk>> fsOtherDisks({
  Iterable<String> Function()? excluded,
}) async {
  List<FsDisk> found;
  if (Platform.isWindows) {
    final system = (Platform.environment['SystemDrive'] ?? 'C:')
        .substring(0, 1)
        .toUpperCase();
    found = [
      for (final drive in await FsPlatform.windowsDrives())
        if (drive.drive != system)
          FsDisk(
            path: drive.directory,
            label: drive.label,
            drive: drive.drive,
            removable: drive.removable,
          ),
    ];
  } else if (Platform.isMacOS) {
    try {
      final mount = await Process.run('/sbin/mount', const []);
      found = macOtherVolumes(mount.stdout as String);
    } catch (_) {
      found = const [];
    }
  } else if (Platform.isLinux) {
    final env = Platform.environment;
    try {
      found = linuxOtherDisks(
        await File('/proc/self/mounts').readAsString(),
        user: env['USER'] ?? env['LOGNAME'] ?? '',
        home: env['HOME'] ?? '',
      );
    } catch (_) {
      found = const [];
    }
  } else {
    found = const [];
  }
  final mounts = [...?excluded?.call()];
  return [
    for (final disk in found)
      if (!mounts.any(
        (mount) => p.equals(mount, disk.path) || p.isWithin(mount, disk.path),
      ))
        disk,
  ];
}

/// The volumes `mount` lists in /Volumes that the Finder shows: local, not
/// hidden (`nobrowse`, like Recovery). Network shares, and so other
/// devices' files Whisper mounts, are not local.
List<FsDisk> macOtherVolumes(String mountOutput) {
  final line = RegExp(r'^.+ on (/Volumes/.+) \(([^()]*)\)$');
  return [
    for (final text in const LineSplitter().convert(mountOutput))
      if (line.firstMatch(text) case final match?)
        if (match.group(2)!.split(', ') case final options
            when options.contains('local') && !options.contains('nobrowse'))
          FsDisk(
            path: match.group(1)!,
            label: p.basename(match.group(1)!),
            removable: true,
          ),
  ];
}

/// Partitions and drives in /proc/self/mounts ([mounts]) that hold the
/// user's things: what udisks mounts for [user] under /media or
/// /run/media, and any other block device mounted outside the system's
/// own folders and not holding [home] (a separate /home is the system's
/// side, like /). Snaps, containers and the like are not block devices or
/// are under those folders.
List<FsDisk> linuxOtherDisks(
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
  String unescape(String field) => field.replaceAllMapped(
    RegExp(r'\\([0-7]{3})'),
    (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 8)),
  );
  final found = <String, FsDisk>{};
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
    found[point] = FsDisk(
      path: point,
      label: p.basename(point),
      removable: onMedia,
    );
  }
  return found.values.toList();
}

/// The disk the system runs from, shared as one with the home folder on
/// it: Windows' `%SystemDrive%` (C:\) with its label, else `/`, named after
/// the volume the Finder shows for it on macOS ("Macintosh HD").
Future<FsDisk> fsSystemDisk() async {
  if (Platform.isWindows) {
    final letter = (Platform.environment['SystemDrive'] ?? 'C:')
        .substring(0, 1)
        .toUpperCase();
    final drive = (await FsPlatform.windowsDrives())
        .where((drive) => drive.drive == letter)
        .firstOrNull;
    return FsDisk(path: '$letter:\\', label: drive?.label ?? '', drive: letter);
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
  return FsDisk(path: '/', label: label);
}

/// What on a disk is the system's or installed programs', which is never
/// shared, by name in lower case: anywhere on Windows, at the top of `/`
/// on macOS and Linux.
const _systemTopNames = {
  'windows': {
    'windows', 'program files', 'program files (x86)', 'programdata', //
    'perflogs', 'recovery', 'windows.old', 'system volume information',
    'config.msi', 'msocache', 'boot', 'documents and settings',
    'onedrivetemp', 'inetpub',
  },
  'macos': {
    'applications', 'library', 'system', 'bin', 'cores', 'dev', 'etc', //
    'home', 'opt', 'private', 'sbin', 'tmp', 'usr', 'var', 'volumes',
    'network', 'net',
  },
  'linux': {
    'bin', 'boot', 'dev', 'efi', 'etc', 'lib', 'lib32', 'lib64', 'libx32', //
    'media', 'mnt', 'nix', 'gnu', 'opt', 'proc', 'root', 'run', 'sbin',
    'snap', 'srv', 'sys', 'tmp', 'usr', 'var', 'swapfile', 'swap.img',
  },
};

/// The same in a home folder: installed apps (macOS), snaps' data (Linux).
/// Windows marks its own there (NTUSER.DAT, the old junctions).
const _systemHomeNames = {
  'macos': {'applications'},
  'linux': {'snap'},
};

/// The system's own folders and files in [roots] (the shared disks, real
/// paths), never shared whatever else is: what is on [systemDisk] for the
/// system and its programs, what starts with a dot or `$` at the top of a
/// disk or is marked as the system's (recycle bins, System Volume
/// Information), the other users' folders beside [home], and installed apps
/// in it. The floor (`FsProtectedAreas`) adds keys, settings and app data.
Future<List<String>> fsSystemFolders({
  required List<String> roots,
  required String systemDisk,
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
    final system = p.equals(root, systemDisk);
    final names = windows || system
        ? _systemTopNames[os] ?? const {}
        : const <String>{};
    await scan(
      root,
      (name, path) =>
          name.startsWith('.') ||
          (windows && name.startsWith(r'$')) ||
          name == 'lost+found' ||
          names.contains(fold(name)) ||
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
