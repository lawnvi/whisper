import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fs_paths.dart';
import 'fs_share_places.dart';
import 'fs_share_policy.dart';

/// What leaving a folder out of [FsSharedFolders] came to.
enum FsExcluded {
  added,

  /// It was not shared already: it is in a folder left out, the system's,
  /// or a place that is never shared ([FsProtectedAreas]).
  already,

  /// It was a whole disk, which was switched off instead.
  disk,
}

/// 「共享的目录」: what devices allowed to browse this computer
/// (`FileBrowsePermissions`) may see, the same for all of them. Disks: the
/// system disk, as the home folder on it, unless switched off; other disks
/// and partitions whole once switched on. In them everything but the system's own folders
/// ([fsSystemFolders]), the floor ([FsProtectedAreas]: keys, settings, app
/// data, Whisper's) and the folders the user left out, each with all in it.
class FsSharedFolders extends ChangeNotifier {
  FsSharedFolders({
    Iterable<String> Function()? mounts,
    Future<FsProtectedAreas> Function()? protectedAreas,
    List<FsRoot> Function()? defaultRoots,
    Future<List<FsCommonFolder>> Function()? commonFolders,
    Future<FsRoot> Function()? systemDisk,
    Future<List<FsRoot>> Function()? disks,
    Future<List<String>> Function(List<String> roots)? systemFolders,
  }) : _protectedAreas =
           protectedAreas ??
           (() => FsProtectedAreas.forThisDevice(mounts: mounts)),
       _defaultRoots = defaultRoots ?? defaultFsRoots,
       _commonFolders = commonFolders,
       _systemDisk = systemDisk ?? fsSystemDisk,
       _disks = disks ?? fsOtherDisks,
       _systemFolders = systemFolders;

  /// Only computers limit browsing; phones offer what a USB cable shows.
  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static const _systemKey = 'remote_files.share_system_disk';
  static const _disksKey = 'remote_files.shared_disks';
  static const _excludedKey = 'remote_files.excluded_folders';

  final Future<FsProtectedAreas> Function() _protectedAreas;
  final List<FsRoot> Function() _defaultRoots;
  final Future<List<FsCommonFolder>> Function()? _commonFolders;
  final Future<FsRoot> Function() _systemDisk;
  final Future<List<FsRoot>> Function() _disks;
  final Future<List<String>> Function(List<String> roots)? _systemFolders;

  bool _systemShared = true;
  List<String> _sharedDisks = const [];
  List<String> _excluded = const [];
  bool _loaded = false;
  FsSharePolicy _policy = FsSharePolicy.none;
  Future<void> _turn = Future.value();

  /// Whether the system disk (its home folder) is shared.
  bool get systemDiskShared => _systemShared;

  /// The other disks switched on, by where they are mounted.
  List<String> get sharedDisks => _sharedDisks;

  /// The folders left out, as they were chosen.
  List<String> get excluded => _excluded;

  /// What other devices may reach right now. Shares nothing until
  /// [refresh] has read the settings.
  FsSharePolicy get policy => _policy;

  /// One change at a time, each seeing the one before.
  Future<T> _serially<T>(Future<T> Function() work) {
    final result = _turn.then((_) => work());
    _turn = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// Reads the settings again and what they share now: disks and folders
  /// come and go.
  Future<void> refresh() => _serially(_reload);

  Future<void> _reload() async {
    final prefs = await SharedPreferences.getInstance();
    _systemShared = prefs.getBool(_systemKey) ?? true;
    _sharedDisks = List.unmodifiable(prefs.getStringList(_disksKey) ?? []);
    _excluded = List.unmodifiable(prefs.getStringList(_excludedKey) ?? []);
    _loaded = true;
    _policy = await _policyFor();
    notifyListeners();
  }

  /// The home folder with its usual folders, which also names them.
  FsRoot? get home =>
      _defaultRoots().where((root) => root.id == 'home').firstOrNull;

  /// The usual folders that are here now, where the system keeps them.
  Future<List<FsCommonFolder>> commonFolders() =>
      _commonFolders?.call() ?? fsCommonFolders(home);

  /// The disk the system runs from.
  Future<FsRoot> systemDisk() => _systemDisk();

  /// The disks and partitions other than the system's that are here now.
  Future<List<FsRoot>> otherDisks() => _disks();

  /// Whether [disk] is shared, the system disk included.
  bool isDiskShared(FsRoot disk, {required bool system}) => system
      ? _systemShared
      : _sharedDisks.any((shared) => p.equals(shared, disk.directory));

  Future<void> shareDisk(FsRoot disk, bool on, {required bool system}) =>
      _serially(() async {
        if (!_loaded) await _reload();
        await _setDisk(system ? null : disk.directory, on);
      });

  /// Switches the disk at [path] on or off, the system disk when null.
  Future<void> _setDisk(String? path, bool on) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      _systemShared = on;
      await prefs.setBool(_systemKey, on);
    } else {
      _sharedDisks = List.unmodifiable([
        for (final shared in _sharedDisks)
          if (!p.equals(shared, path)) shared,
        if (on) path,
      ]);
      await prefs.setStringList(_disksKey, _sharedDisks);
    }
    await _changed();
  }

  /// Leaves [folder] out, with everything in it. One already left out, or
  /// in a folder that is, is [FsExcluded.already]; folders left out inside
  /// it go in with it.
  Future<FsExcluded> exclude(String folder) => _serially(() async {
    if (!_loaded) await _reload();
    final real = await fsCanonical(folder);
    final system = await _systemDisk();
    final share = _systemShare;
    if (p.equals(real, await fsCanonical(system.directory)) ||
        (share != null && p.equals(real, await fsCanonical(share)))) {
      await _setDisk(null, false);
      return FsExcluded.disk;
    }
    for (final disk in _sharedDisks) {
      if (p.equals(real, await fsCanonical(disk))) {
        await _setDisk(disk, false);
        return FsExcluded.disk;
      }
    }
    if (_policy.shared.any((root) => FsPathResolver.isInside(root, real)) &&
        !_policy.allows(real, FsUse.read)) {
      return FsExcluded.already;
    }
    // On the system disk only the home folder is ever shared.
    var onOtherDisk = false;
    for (final disk in [
      ..._sharedDisks,
      for (final disk in await _disks()) disk.directory,
    ]) {
      onOtherDisk =
          onOtherDisk || FsPathResolver.isInside(await fsCanonical(disk), real);
    }
    if (!onOtherDisk &&
        share != null &&
        !FsPathResolver.isInside(await fsCanonical(share), real)) {
      return FsExcluded.already;
    }
    final kept = <String>[];
    for (final other in _excluded) {
      final otherReal = await fsCanonical(other);
      if (FsPathResolver.isInside(otherReal, real)) {
        return FsExcluded.already;
      }
      if (!p.isWithin(real, otherReal)) {
        kept.add(other);
      }
    }
    _excluded = List.unmodifiable([...kept, folder]);
    await (await SharedPreferences.getInstance()).setStringList(
      _excludedKey,
      _excluded,
    );
    await _changed();
    return FsExcluded.added;
  });

  /// Shares [folder] again, as it was left out.
  Future<void> include(String folder) => _serially(() async {
    if (!_loaded) await _reload();
    _excluded = List.unmodifiable([
      for (final other in _excluded)
        if (other != folder) other,
    ]);
    await (await SharedPreferences.getInstance()).setStringList(
      _excludedKey,
      _excluded,
    );
    await _changed();
  });

  Future<void> _changed() async {
    _policy = await _policyFor();
    notifyListeners();
  }

  /// What sharing the system disk shares: the home folder on it. The rest
  /// of it is the system's and installed programs', which no rule tells
  /// apart from the user's well enough (C:\Python311, /pkg).
  String? get _systemShare => home?.directory;

  Future<FsSharePolicy> _policyFor() async {
    final protected = await _protectedAreas();
    final roots = <String>[];
    for (final disk in [
      if (_systemShared && _systemShare != null) _systemShare!,
      ..._sharedDisks,
    ]) {
      final real = await _real(disk);
      if (real != null &&
          !protected.blocksRead(real) &&
          !roots.any((other) => p.equals(other, real))) {
        roots.add(real);
      }
    }
    // A disk switched off is not shared where another one holds it: Linux
    // mounts partitions in the home folder too (~/data).
    final offInside = <String>[];
    for (final disk in await _disks()) {
      final real = await _real(disk.directory);
      if (real != null &&
          !roots.any((root) => p.equals(root, real)) &&
          roots.any((root) => p.isWithin(root, real))) {
        offInside.add(real);
      }
    }
    final systemFolders = _systemFolders;
    final homeDirectory = home?.directory;
    final excluded = [
      ...offInside,
      ...systemFolders != null
          ? await systemFolders(roots)
          : await fsSystemFolders(
              roots: roots,
              home: homeDirectory == null
                  ? ''
                  : await _real(homeDirectory) ?? homeDirectory,
            ),
      for (final folder in _excluded) await fsCanonical(folder),
    ];
    return FsSharePolicy(
      shared: roots,
      protected: protected,
      excluded: excluded,
    );
  }

  /// [folder] with its symlinks followed, or null when it is not there.
  static Future<String?> _real(String folder) async {
    try {
      if (await FileSystemEntity.type(folder) !=
          FileSystemEntityType.directory) {
        return null;
      }
      return await Directory(folder).resolveSymbolicLinks();
    } on FileSystemException {
      return null;
    }
  }

  /// Whether [folder] is there now (a USB stick may not be).
  static Future<bool> exists(String folder) async =>
      await _real(folder) != null;

  /// What this computer offers now, read afresh: see [offeredFsRoots].
  Future<List<FsRoot>> roots() async {
    await refresh();
    final policy = _policy;
    final common = [
      for (final folder in await commonFolders())
        if (await _real(folder.path) case final real?)
          FsCommonFolder(kind: folder.kind, path: real),
    ];
    return offeredFsRoots(policy, [
      ..._defaultRoots(),
      ...await _disks(),
    ], common: common);
  }
}

/// The roots that reach what [policy] shares: each of this computer's
/// [places] (the home folder, the other disks) that may be read. A place's
/// usual folders are shortcuts, unless the user left them out; a usual
/// folder kept elsewhere ([common], real paths, such as Documents moved
/// into OneDrive or onto D:) is one of the innermost place holding it.
Future<List<FsRoot>> offeredFsRoots(
  FsSharePolicy policy,
  List<FsRoot> places, {
  List<FsCommonFolder> common = const [],
}) async {
  final bases = [
    for (final place in places) await fsCanonical(place.directory),
  ];
  final byKind = {for (final folder in common) folder.kind: folder.path};
  final roots = <FsRoot>[];
  for (final (i, place) in places.indexed) {
    final base = bases[i];
    if (!policy.allows(base, FsUse.read)) {
      continue;
    }
    String at(String relative) => p.joinAll([base, ...relative.split('/')]);
    // The innermost place holding a usual folder gets its shortcut.
    bool innermost(String path) => !bases.any(
      (other) =>
          other.length > base.length &&
          p.isWithin(base, other) &&
          (p.equals(other, path) || p.isWithin(other, path)),
    );
    final shortcuts = <FsShortcut>[
      for (final shortcut in place.shortcuts)
        if (byKind[shortcut.kind] case final moved
            when moved == null || p.equals(moved, at(shortcut.path)))
          if (policy.allows(at(shortcut.path), FsUse.read)) shortcut,
    ];
    for (final folder in common) {
      if (p.isWithin(base, folder.path) &&
          innermost(folder.path) &&
          policy.allows(folder.path, FsUse.read) &&
          !shortcuts.any(
            (shortcut) => p.equals(at(shortcut.path), folder.path),
          )) {
        shortcuts.add(
          FsShortcut(
            kind: folder.kind,
            path: p.split(p.relative(folder.path, from: base)).join('/'),
          ),
        );
      }
    }
    roots.add(
      FsRoot(
        id: place.id,
        directory: place.directory,
        shortcuts: shortcuts,
        kind: place.kind,
        label: place.label,
        drive: place.drive,
        removable: place.removable,
      ),
    );
  }
  return roots;
}
