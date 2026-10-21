import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_files_windows.dart';
import 'fuse_linux.dart';
import 'mount_macos.dart';
import 'mount_tree.dart';
import 'nfs_server.dart';

/// How one system shows a [MountTree]: macOS through its NFS client,
/// Linux with FUSE, Windows as a Cloud Files sync root. Each runs in a
/// [MountWorker] isolate; [prepare], [cleanUp] and [missing] run in the
/// app's.
abstract class MountFrontend {
  /// Where the system shows it: what to open in its file manager.
  String get path;

  /// Shows [tree] as [name] at [path].
  Future<void> start(MountTree tree, String name);

  /// Takes it away again.
  Future<void> stop();

  /// Set before [start]: the system took it away itself (ejected in the
  /// file manager).
  void Function()? onEnded;

  /// See [MountTree.idleCommit]: for a system that may never say it is
  /// done writing a file.
  Duration? get idleCommit => null;

  /// See [MountTree.keepHere]: what this system writes for itself.
  bool Function(String name)? get keepHere => null;

  /// Takes away what a run before this one left behind.
  static Future<void> cleanUp() async {
    if (Platform.isMacOS) {
      final base = await _macBase();
      for (final point in await MacNfsMount.mountedUnder(base)) {
        await MacNfsMount.unmount(point);
      }
    } else if (Platform.isLinux) {
      await FuseMount.unmountAllUnder(_linuxBase());
    } else if (Platform.isWindows) {
      CloudFilesMount.unregisterStale();
      // Only folders Whisper made sync roots of: they hold nothing but
      // what was read from the device.
      for (final folder in await recordedFolders()) {
        try {
          await Directory(folder).delete(recursive: true);
        } on FileSystemException {
          // In use; next start.
          continue;
        }
        await recordFolder(folder, false);
      }
      try {
        await Directory(_windowsBase()).delete();
      } on FileSystemException {
        // Not there, or something else in it.
      }
    }
  }

  /// Whether this system can mount at all; null when it can, else what
  /// is missing.
  static Future<MountMissing?> missing() async {
    if (Platform.isMacOS) {
      return null;
    }
    if (Platform.isLinux) {
      return await FuseMount.helper() == null ? MountMissing.fuse : null;
    }
    if (Platform.isWindows) {
      return null;
    }
    return MountMissing.platform;
  }

  /// Where and how this system mounts [peerId]'s files as [name]; null
  /// when it does not mount at all.
  static Future<({String kind, String path})?> prepare({
    required String peerId,
    required String name,
  }) async {
    if (Platform.isMacOS) {
      final safe = peerId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      return (kind: 'nfs', path: '${await _macBase()}/$safe');
    }
    if (Platform.isLinux) {
      return (kind: 'fuse', path: await _linuxPoint(name));
    }
    if (Platform.isWindows) {
      final path = await _windowsPoint(name);
      // Recorded before anything is in it, so that a crash leaves nothing
      // the next start does not clear.
      await recordFolder(path, true);
      return (kind: 'cloudFiles', path: path);
    }
    return null;
  }

  /// The frontend of [kind] (from [prepare]), in the worker isolate.
  static MountFrontend create(String kind, String path, String device) =>
      switch (kind) {
        'nfs' => _MacFrontend(path),
        'fuse' => _LinuxFrontend(path),
        'cloudFiles' => _WindowsFrontend(path, device),
        _ => throw ArgumentError.value(kind, 'kind'),
      };

  /// Takes away a mount of [kind] at [path] whose worker died: nothing
  /// answers it any more, and on Linux whatever touches it would wait.
  static Future<void> release(String kind, String path) async {
    switch (kind) {
      case 'nfs':
        await MacNfsMount.unmount(path);
      case 'fuse':
        final helper = await FuseMount.helper();
        if (helper != null) {
          await Process.run(helper, ['-u', '-z', path]);
        }
      case 'cloudFiles':
        CloudFilesMount.unregisterStale();
        try {
          await Directory(path).delete(recursive: true);
        } on FileSystemException {
          // Cleared at the next start.
        }
    }
  }

  /// The mount at [path] is gone: on Windows its sync root folder no
  /// longer needs clearing at the next start.
  static Future<void> forget(String path) async {
    if (Platform.isWindows && !await Directory(path).exists()) {
      await recordFolder(path, false);
    }
  }

  static const _foldersKey = 'remote_files.sync_root_folders';

  /// Sync root folders Whisper made and has not removed yet.
  static Future<List<String>> recordedFolders() async =>
      (await SharedPreferences.getInstance()).getStringList(_foldersKey) ??
      const [];

  static Future<void> recordFolder(String folder, bool made) async {
    final preferences = await SharedPreferences.getInstance();
    final folders = {...?preferences.getStringList(_foldersKey)};
    if (made ? folders.add(folder) : folders.remove(folder)) {
      await preferences.setStringList(_foldersKey, folders.toList());
    }
  }

  /// Windows shows a sync root under its own name in Explorer's
  /// navigation pane; its folder is %USERPROFILE%\Whisper\<device>.
  static String _windowsBase() =>
      '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? r'C:\'}\\Whisper';

  static Future<String> _windowsPoint(String name) async {
    var safe = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
          caseSensitive: false,
        ).hasMatch(safe)) {
      safe = 'Whisper $safe'.trim();
    }
    final base = _windowsBase();
    var point = '$base\\$safe';
    for (var n = 2; await _taken(point); n++) {
      point = '$base\\$safe $n';
    }
    return point;
  }

  /// macOS lists a mount by its own name, so it goes out of the way.
  /// Its real path, as `mount` prints it.
  static Future<String> _macBase() async {
    final support = await getApplicationSupportDirectory();
    final base = Directory('${support.path}/Mounts');
    await base.create(recursive: true);
    return base.resolveSymbolicLinks();
  }

  /// Linux file managers name a mount after its folder and list it when
  /// it is in the home folder: ~/Whisper/<device>.
  static String _linuxBase() =>
      '${Platform.environment['HOME'] ?? '/tmp'}/Whisper';

  static Future<String> _linuxPoint(String name) async {
    final base = _linuxBase();
    var safe = name.replaceAll('/', '∕').trim();
    if (safe.isEmpty || safe == '.' || safe == '..') {
      safe = 'Whisper';
    }
    var point = '$base/$safe';
    for (var n = 2; await _taken(point); n++) {
      point = '$base/$safe $n';
    }
    return point;
  }

  /// A folder already there with something in it (another device of the
  /// same name, or the user's own).
  static Future<bool> _taken(String point) async {
    final dir = Directory(point);
    if (!await dir.exists()) {
      return false;
    }
    if (Platform.isLinux && await FuseMount.isMounted(point)) {
      return true;
    }
    return !(await dir.list().isEmpty);
  }
}

/// What this system lacks for mounting.
enum MountMissing {
  /// Linux without FUSE (the fuse3 package).
  fuse,

  /// Not done for this system.
  platform,
}

class _WindowsFrontend extends MountFrontend {
  _WindowsFrontend(this.path, this.device);

  @override
  final String path;
  final String device;

  CloudFilesMount? _mount;

  @override
  Future<void> start(MountTree tree, String name) async {
    final mount = CloudFilesMount(tree, path: path, device: device, name: name);
    _mount = mount;
    try {
      await mount.start();
    } catch (_) {
      try {
        await Directory(path).delete(recursive: true);
      } on FileSystemException {
        // Left for the next start's clean-up.
      }
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    await _mount?.stop();
  }
}

class _LinuxFrontend extends MountFrontend {
  _LinuxFrontend(this.path);

  @override
  final String path;

  FuseMount? _fuse;

  @override
  Future<void> start(MountTree tree, String name) async {
    final fuse = FuseMount(tree, mountPoint: path, name: name)
      ..onEnded = () {
        _tidy();
        onEnded?.call();
      };
    _fuse = fuse;
    await fuse.start();
  }

  @override
  Future<void> stop() async {
    await _fuse?.stop();
    _tidy();
  }

  /// ~/Whisper goes with its last mount.
  void _tidy() {
    try {
      Directory(File(path).parent.path).deleteSync();
    } on FileSystemException {
      // Another device is still mounted there.
    }
  }
}

class _MacFrontend extends MountFrontend {
  _MacFrontend(this.path);

  @override
  final String path;

  /// macOS commits on close what it wrote as "unstable", but what it
  /// wrote "file sync" it never does.
  @override
  Duration get idleCommit => const Duration(seconds: 2);

  /// Extended attributes (Finder tags, where a download came from) as
  /// `._name` AppleDouble files, which NFSv3 leaves to the client, and
  /// Finder's `.DS_Store`: the other device gets none of them.
  @override
  bool Function(String name) get keepHere =>
      (name) => name.startsWith('._') || name == '.DS_Store';

  NfsServer? _server;
  bool _mounted = false;
  bool _stopping = false;
  Timer? _watch;

  @override
  Future<void> start(MountTree tree, String name) async {
    final server = NfsServer(tree, volumeName: name);
    _server = server;
    // An eject seldom says so (UMNT): the client hangs up, and the mount
    // is gone from the system's list.
    server
      ..onUnmounted = _check
      ..onDisconnected = () {
        Timer(const Duration(milliseconds: 300), _check);
      };
    await server.start();
    try {
      await MacNfsMount.mount(
        port: server.port,
        export: server.exportPath,
        mountPoint: path,
        writable: tree.writable,
      );
    } catch (_) {
      await server.close();
      rethrow;
    }
    _mounted = true;
    _watch = Timer.periodic(const Duration(seconds: 15), (_) => _check());
  }

  bool _checking = false;

  Future<void> _check() async {
    if (!_mounted || _stopping || _checking) {
      return;
    }
    _checking = true;
    try {
      final points = await MacNfsMount.mountedUnder(File(path).parent.path);
      if (!points.contains(path) && !_stopping) {
        await _ended();
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _ended() async {
    _stopping = true;
    _watch?.cancel();
    await _server?.close();
    try {
      await Directory(path).delete();
    } on FileSystemException {
      // Something else is there.
    }
    onEnded?.call();
  }

  @override
  Future<void> stop() async {
    if (_stopping) {
      return;
    }
    _stopping = true;
    _watch?.cancel();
    // Unmount first: the system still asks the server on the way out.
    await MacNfsMount.unmount(path);
    await _server?.close();
  }
}
