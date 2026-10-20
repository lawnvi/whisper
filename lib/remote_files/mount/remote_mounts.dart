import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../files_log.dart';
import '../fs_client.dart';
import '../fs_host_files.dart';
import '../fs_protocol.dart';
import 'mount_frontend.dart';
import 'mount_worker.dart';
import 'mount_tree.dart';

/// The other device's files through its browse session.
class RemoteMountSource implements MountSource {
  RemoteMountSource(this.client);

  final RemoteFilesClient client;

  @override
  Future<List<FsEntry>> list(String root, String path) async {
    final entries = <FsEntry>[];
    var offset = 0;
    while (true) {
      final page = await _guard(
        () => client.list(root, path, offset: offset, showHidden: true),
      );
      entries.addAll(page.entries);
      if (!page.hasMore || page.entries.isEmpty) {
        return entries;
      }
      offset = page.offset + page.entries.length;
    }
  }

  @override
  Future<Uint8List> read(String root, String path, int offset, int length) =>
      _guard(() => client.read(root, path, offset, length));

  Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on RemoteFsException catch (error) {
      throw MountException(switch (error.reason) {
        FileBrowseError.notFound => MountError.notFound,
        'offline' || FileBrowseError.notAllowed => MountError.offline,
        _ => MountError.io,
      });
    }
  }
}

/// Why mounting did not happen.
enum MountFailure {
  /// This system has no way to mount here yet.
  unsupported,

  /// Linux without FUSE: the fuse3 package is missing.
  noFuse,

  /// The other device's Whisper is too old to read parts of files.
  hostTooOld,

  /// Its user did not allow browsing.
  denied,

  /// It went away, or did not answer.
  offline,

  /// The system refused the mount.
  system,
}

class MountFailed implements Exception {
  const MountFailed(this.failure);

  final MountFailure failure;

  @override
  String toString() => 'MountFailed(${failure.name})';
}

/// A device's files mounted here.
class RemoteMount {
  RemoteMount._(this.peerId, this.name, this.path);

  final String peerId;
  final String name;

  /// Where the system shows it: what to open in the file manager.
  final String path;
}

/// Mounts other devices' files into the system's file manager, one mount
/// per device, for as long as Whisper runs and the device stays
/// connected. Whisper only opens and closes the way in: browsing, opening
/// and copying are the system's own.
///
/// "挂载到本机" is remembered per device: it mounts again whenever that
/// device connects, until it is turned off or ejected in the file manager.
class RemoteMounts extends ChangeNotifier {
  RemoteMounts({SharedPreferences? preferences}) : _preferences = preferences {
    mountLog = FilesLog.write;
  }

  static final RemoteMounts shared = RemoteMounts();

  static const _key = 'remote_files.mounted_peers';

  /// Names a device's roots as the top folders of its mount; set by the
  /// app with its own words ("C 盘", "内部存储").
  String Function(RemoteFsRoot root) rootNamer = _plainRootName;

  SharedPreferences? _preferences;
  Set<String>? _wanted;
  final _mounts = <String, _Active>{};
  final _starting = <String, Future<RemoteMount>>{};
  final _failures = <String, MountFailure>{};

  /// Systems that mount other devices' files: macOS (its NFS client),
  /// Linux (FUSE) and Windows (Cloud Files).
  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  RemoteMount? of(String peerId) => _mounts[peerId]?.mount;

  bool isMounting(String peerId) => _starting.containsKey(peerId);

  Iterable<RemoteMount> get all => _mounts.values.map((active) => active.mount);

  /// Why mounting [peerId] last failed, until it is tried again.
  MountFailure? failureOf(String peerId) => _failures[peerId];

  /// "挂载到本机" is on for [peerId].
  bool wants(String peerId) => _wanted?.contains(peerId) ?? false;

  Future<Set<String>> _loadWanted() async {
    final loaded = _wanted;
    if (loaded != null) {
      return loaded;
    }
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    return _wanted ??= {...?preferences.getStringList(_key)};
  }

  Future<void> _remember(String peerId, bool wanted) async {
    final set = await _loadWanted();
    if (!(wanted ? set.add(peerId) : set.remove(peerId))) {
      return;
    }
    notifyListeners();
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    await preferences.setStringList(_key, set.toList());
  }

  /// Reads what was remembered (once, at start).
  Future<void> load() async {
    await _loadWanted();
    notifyListeners();
  }

  /// Turns "挂载到本机" on or off for [peerId]; on mounts it now when it is
  /// connected ([name] is the volume's name).
  Future<RemoteMount?> setWanted(
    String peerId,
    String name,
    bool wanted,
  ) async {
    await _remember(peerId, wanted);
    if (!wanted) {
      await unmount(peerId);
      return null;
    }
    try {
      return await mount(peerId, name);
    } on MountFailed catch (failed) {
      if (failed.failure != MountFailure.offline) {
        // Refused or impossible: it is not left on to fail again.
        await _remember(peerId, false);
      }
      rethrow;
    }
  }

  /// [peerId] connected and speaks the file-browse protocol: mounts it if
  /// "挂载到本机" is on for it.
  Future<void> peerConnected(String peerId, String name) async {
    if (!supported || !(await _loadWanted()).contains(peerId)) {
      return;
    }
    try {
      await mount(peerId, name);
    } on MountFailed catch (failed) {
      FilesLog.write(
        'mount: $peerId not mounted on connect: ${failed.failure.name}',
      );
      if (failed.failure == MountFailure.hostTooOld ||
          failed.failure == MountFailure.denied) {
        await _remember(peerId, false);
      }
    }
  }

  /// Mounts [peerId]'s files as [name], asking its user first unless it
  /// already lets this device browse.
  Future<RemoteMount> mount(String peerId, String name) {
    final existing = _mounts[peerId];
    if (existing != null) {
      return Future.value(existing.mount);
    }
    return _starting[peerId] ??= _mount(peerId, name).whenComplete(() {
      _starting.remove(peerId);
      notifyListeners();
    });
  }

  Future<RemoteMount> _mount(String peerId, String name) async {
    _failures.remove(peerId);
    notifyListeners();
    try {
      return await _mountNow(peerId, name);
    } on MountFailed catch (failed) {
      _failures[peerId] = failed.failure;
      rethrow;
    }
  }

  Future<RemoteMount> _mountNow(String peerId, String name) async {
    final missing = supported
        ? await MountFrontend.missing()
        : MountMissing.platform;
    if (missing != null) {
      throw MountFailed(
        missing == MountMissing.fuse
            ? MountFailure.noFuse
            : MountFailure.unsupported,
      );
    }
    final client = RemoteFilesClient(peerId);
    final RemoteFsInfo info;
    try {
      info = await client.open();
    } on RemoteFsException catch (error) {
      throw MountFailed(
        error.reason == 'denied' || error.reason == 'noAnswer'
            ? MountFailure.denied
            : MountFailure.offline,
      );
    }
    if (!info.canRead) {
      await client.close();
      throw const MountFailed(MountFailure.hostTooOld);
    }
    final names = <String>{};
    final roots = [
      for (final root in info.roots)
        MountRoot(id: root.id, name: _unique(names, rootNamer(root))),
    ];
    final place = await MountFrontend.prepare(peerId: peerId, name: name);
    if (place == null) {
      await client.close();
      throw const MountFailed(MountFailure.unsupported);
    }
    final MountWorker worker;
    try {
      worker = await MountWorker.start(
        source: RemoteMountSource(client),
        roots: roots,
        kind: place.kind,
        path: place.path,
        device: peerId,
        name: name,
        // Windows can hide hidden files itself; Finder and Linux file
        // managers only hide names starting with a dot.
        showHiddenFiles: Platform.isWindows,
      );
    } catch (error) {
      FilesLog.write('mount: system refused: $error');
      await client.close();
      await MountFrontend.forget(place.path);
      throw const MountFailed(MountFailure.system);
    }
    final mount = RemoteMount._(peerId, name, worker.path);
    final active = _Active(mount, client, worker, place.kind);
    worker.onEnded = () => unawaited(_ended(peerId, active));
    _mounts[peerId] = active;
    FilesLog.write('mount: ${roots.length} root(s) of $peerId mounted');
    unawaited(
      client.gone.then((_) {
        if (identical(_mounts[peerId], active)) {
          FilesLog.write('mount: $peerId went away');
          unawaited(unmount(peerId));
        }
      }),
    );
    return mount;
  }

  /// Ejected in the file manager: it stays off until turned on again.
  /// Its worker died instead: the mount goes, "挂载到本机" stays on.
  Future<void> _ended(String peerId, _Active active) async {
    if (!identical(_mounts[peerId], active)) {
      return;
    }
    _mounts.remove(peerId);
    notifyListeners();
    final died = active.worker.died;
    FilesLog.write(
      died
          ? 'mount: $peerId lost its worker'
          : 'mount: $peerId ejected in the file manager',
    );
    if (died) {
      await MountFrontend.release(active.kind, active.mount.path);
    } else {
      await active.worker.stop();
    }
    await active.client.close();
    await MountFrontend.forget(active.mount.path);
    if (!died) {
      await _remember(peerId, false);
    }
  }

  static String _plainRootName(RemoteFsRoot root) => root.name.isNotEmpty
      ? root.name
      : root.drive.isNotEmpty
      ? root.drive
      : root.id;

  static String _unique(Set<String> taken, String name) {
    var candidate = name.isEmpty ? '?' : name;
    for (var n = 2; !taken.add(candidate); n++) {
      candidate = '$name $n';
    }
    return candidate;
  }

  /// Takes [peerId]'s files out of the file manager (until it connects
  /// again, when "挂载到本机" stays on).
  Future<void> unmount(String peerId) async {
    final active = _mounts.remove(peerId);
    if (active == null) {
      return;
    }
    notifyListeners();
    await active.worker.stop();
    await active.client.close();
    await MountFrontend.forget(active.mount.path);
  }

  /// Whisper is quitting.
  Future<void> unmountAll() async {
    for (final peerId in _mounts.keys.toList()) {
      await unmount(peerId);
    }
  }

  /// Mounts a run before this one did not get to take away (it quit
  /// abruptly): nothing answers them any more.
  Future<void> cleanUpStale() async {
    if (!supported) {
      return;
    }
    try {
      await MountFrontend.cleanUp();
    } catch (error) {
      FilesLog.write('mount: stale clean-up failed: $error');
    }
  }
}

class _Active {
  _Active(this.mount, this.client, this.worker, this.kind);

  final RemoteMount mount;
  final RemoteFilesClient client;
  final MountWorker worker;
  final String kind;
}
