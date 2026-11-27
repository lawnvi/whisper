import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../files_log.dart';
import '../fs_client.dart';
import '../fs_host_files.dart';
import '../fs_protocol.dart';
import 'mount_frontend.dart';
import 'mount_tree.dart';
import 'mount_worker.dart';

/// How long a mounted folder stays alive after a transient disconnect while
/// waiting for the peer to reconnect with the same identity key.
const Duration mountDisconnectGracePeriod = Duration(seconds: 60);

/// How long an individual mount I/O call waits for reconnect during the grace
/// period before failing with an I/O error so Finder/Explorer never hangs.
const Duration mountReconnectRequestWait = Duration(seconds: 5);

/// Test hook that stands in for spawning an OS mount worker.
typedef MountStarter =
    Future<({String path, Future<void> Function() stop})> Function(
      RemoteMountSource source,
      List<MountRoot> roots,
      String peerId,
      String name,
    );

/// The other device's files through its browse session, supporting transient
/// suspension during the disconnect grace period and rebinding to a fresh
/// session once the same peer reconnects.
class RemoteMountSource extends MountSource {
  RemoteMountSource(
    RemoteFilesClient client, {
    bool writable = false,
    bool hasTrash = true,
    this.reconnectWait = mountReconnectRequestWait,
  }) : _client = client,
       _writable = writable,
       _hasTrash = hasTrash;

  RemoteFilesClient? _client;
  bool _writable;
  bool _hasTrash;
  final Duration reconnectWait;

  /// Completed with `true` when rebound to a fresh session, or `false` when
  /// the mount is unmounted/revoked while suspended.
  Completer<bool>? _reconnected;

  /// Upload ids opened on the current browse session only. Cleared on every
  /// disconnect/rebind so half-written uploads never resume or commit on a new
  /// session.
  final Set<String> _sessionUploads = <String>{};

  RemoteFilesClient? get client => _client;

  bool get isSuspended => _client == null && _reconnected != null;

  /// Its host takes changes and lets this device make them.
  @override
  bool get writable => _writable;

  /// Deletions there go to a trash (not on Android).
  bool get hasTrash => _hasTrash;

  /// Enters the transient disconnect grace period: in-flight uploads are
  /// invalidated and new non-upload requests wait up to [reconnectWait].
  void suspend() {
    _client = null;
    _sessionUploads.clear();
    _reconnected ??= Completer<bool>();
  }

  /// Rebinds to a freshly authenticated and permission-checked [nextClient].
  void rebind(
    RemoteFilesClient nextClient, {
    required bool writable,
    required bool hasTrash,
  }) {
    _client = nextClient;
    _writable = writable;
    _hasTrash = hasTrash;
    _sessionUploads.clear();
    final waiter = _reconnected;
    _reconnected = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(true);
    }
  }

  /// Ends suspension without reconnecting (unmount, revoke, or grace expiry),
  /// waking any waiting requests immediately with an I/O error.
  void failSuspended() {
    _client = null;
    _sessionUploads.clear();
    final waiter = _reconnected;
    _reconnected = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(false);
    }
  }

  Future<RemoteFilesClient> _requireClient() async {
    final current = _client;
    if (current != null) {
      return current;
    }
    final waiter = _reconnected;
    if (waiter == null) {
      throw const MountException(MountError.offline);
    }
    final resumed = await waiter.future.timeout(
      reconnectWait,
      onTimeout: () => false,
    );
    final rebound = _client;
    if (!resumed || rebound == null) {
      throw const MountException(MountError.io);
    }
    return rebound;
  }

  /// Upload-scoped operations (`write`, `writeSize`, `readUpload`,
  /// `writeClose`) never wait for reconnect and never cross sessions: an
  /// upload interrupted by disconnect fails immediately.
  RemoteFilesClient _requireUploadClient(String upload) {
    final current = _client;
    if (current == null || !_sessionUploads.contains(upload)) {
      throw const MountException(MountError.io);
    }
    return current;
  }

  @override
  Future<List<FsEntry>> list(String root, String path) =>
      _guardReadOnly((client) async {
        final entries = <FsEntry>[];
        var offset = 0;
        while (true) {
          final page = await client.list(
            root,
            path,
            offset: offset,
            showHidden: true,
          );
          entries.addAll(page.entries);
          if (!page.hasMore || page.entries.isEmpty) {
            return entries;
          }
          offset += page.entries.length;
        }
      });

  @override
  Future<FsEntry?> stat(String root, String path) =>
      _guardReadOnly((client) => client.stat(root, path));

  @override
  Future<Uint8List> read(String root, String path, int offset, int length) =>
      _guardReadOnly((client) => client.read(root, path, offset, length));

  @override
  Future<Uint8List> readUpload(String upload, int offset, int length) {
    final client = _requireUploadClient(upload);
    return _guard(() => client.read('', '', offset, length, upload: upload));
  }

  @override
  Future<FsEntry> create(String root, String parent, String name) async {
    final client = await _requireClient();
    return _guard(() => client.create(root, parent, name));
  }

  @override
  Future<void> mkdir(String root, String parent, String name) async {
    final client = await _requireClient();
    return _guard(() => client.mkdir(root, parent, name));
  }

  @override
  Future<void> remove(
    String root,
    String path, {
    bool folder = false,
    bool permanent = false,
  }) async {
    final client = await _requireClient();
    return _guard(
      () => client.remove(
        root,
        path,
        folder: folder,
        permanent: folder || permanent || !_hasTrash,
      ),
    );
  }

  @override
  Future<void> move(
    String root,
    String path,
    String parent,
    String name,
  ) async {
    final client = await _requireClient();
    return _guard(() => client.move(root, path, parent, name));
  }

  @override
  Future<void> touch(String root, String path, int modifiedMs) async {
    final client = await _requireClient();
    return _guard(() => client.touch(root, path, modifiedMs));
  }

  @override
  Future<({int total, int free})?> space(String root) =>
      _guardReadOnly((client) => client.space(root));

  @override
  Future<({String id, int size})> writeOpen(
    String root,
    String path, {
    required bool truncate,
  }) async {
    final client = await _requireClient();
    final opened = await _guard(
      () => client.writeOpen(root, path, truncate: truncate),
    );
    if (identical(_client, client)) {
      _sessionUploads.add(opened.id);
    }
    return opened;
  }

  @override
  Future<void> write(String upload, int offset, Uint8List data) {
    final client = _requireUploadClient(upload);
    return _guard(() => client.write(upload, offset, data));
  }

  @override
  Future<void> writeSize(String upload, int size) {
    final client = _requireUploadClient(upload);
    return _guard(() => client.writeSize(upload, size));
  }

  @override
  Future<({String path, FsEntry? entry})> writeClose(
    String upload, {
    required bool commit,
    int? modifiedMs,
  }) async {
    final client = _requireUploadClient(upload);
    try {
      return await _guard(
        () => client.writeClose(upload, commit: commit, modifiedMs: modifiedMs),
      );
    } finally {
      _sessionUploads.remove(upload);
    }
  }

  Future<T> _guardReadOnly<T>(
    Future<T> Function(RemoteFilesClient client) request,
  ) async {
    final client = await _requireClient();
    try {
      return await request(client);
    } on RemoteFsException catch (error) {
      if (error.reason == 'offline' && _reconnected != null) {
        // The link dropped mid-read and entered grace period; wait briefly for
        // reconnect and retry once on the new session.
        final rebound = await _requireClient();
        return _guard(() => request(rebound));
      }
      throw _mapError(error);
    }
  }

  Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on RemoteFsException catch (error) {
      throw _mapError(error);
    }
  }

  static MountException _mapError(RemoteFsException error) =>
      MountException(switch (error.reason) {
        FileBrowseError.notFound => MountError.notFound,
        FileBrowseError.exists => MountError.exists,
        FileBrowseError.notEmpty => MountError.notEmpty,
        FileBrowseError.readOnly => MountError.readOnly,
        FileBrowseError.badName => MountError.invalid,
        'offline' || FileBrowseError.notAllowed => MountError.offline,
        _ => MountError.io,
      });
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
/// connected (with a brief [gracePeriod] on transient network drops so a short
/// blip does not eject the volume). Whisper only opens and closes the way in:
/// browsing, opening and copying are the system's own.
///
/// "挂载到本机" is remembered per device: it mounts again whenever that
/// device connects, until it is turned off or ejected in the file manager.
class RemoteMounts extends ChangeNotifier {
  RemoteMounts({
    SharedPreferences? preferences,
    this.gracePeriod = mountDisconnectGracePeriod,
    this.reconnectWait = mountReconnectRequestWait,
    this.peerIdentityKey,
    @visibleForTesting this.startMount,
  }) : _preferences = preferences {
    mountLog = FilesLog.write;
  }

  static final RemoteMounts shared = RemoteMounts().._hideFromHost();

  static const _key = 'remote_files.mounted_peers';

  final Duration gracePeriod;
  final Duration reconnectWait;

  /// Returns the currently authenticated session's pinned identity public key
  /// for [peerId], used to verify reconnects before resuming a suspended mount.
  String? Function(String peerId)? peerIdentityKey;

  @visibleForTesting
  final MountStarter? startMount;

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

  @visibleForTesting
  RemoteMountSource? sourceOf(String peerId) => _mounts[peerId]?.source;

  bool isMounting(String peerId) => _starting.containsKey(peerId);

  bool isSuspended(String peerId) => _mounts[peerId]?.inGracePeriod ?? false;

  Iterable<RemoteMount> get all => _mounts.values.map((active) => active.mount);

  /// What is mounted here is never served to a device browsing this one:
  /// it would find itself, or another device, and could go round in it.
  void _hideFromHost() {
    FsHostFiles.excluded = () => {for (final mount in all) mount.path};
  }

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

  /// [peerId] connected and speaks the file-browse protocol: resumes a
  /// suspended mount (after verifying [identityPublicKey] and re-checking
  /// host permissions), or mounts it fresh if "挂载到本机" is on.
  Future<void> peerConnected(
    String peerId,
    String name, {
    String? identityPublicKey,
  }) async {
    final active = _mounts[peerId];
    if (active != null && active.inGracePeriod) {
      await _resumeMount(
        peerId,
        active,
        identityPublicKey: identityPublicKey ?? peerIdentityKey?.call(peerId),
      );
      return;
    }
    if ((!supported && startMount == null) ||
        !(await _loadWanted()).contains(peerId)) {
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

  /// Trust was revoked, the device was deleted, or the peer explicitly
  /// disconnected/stopped offering files: immediately unmount without grace.
  Future<void> peerRevoked(String peerId) => unmount(peerId);

  Future<void> _resumeMount(
    String peerId,
    _Active active, {
    String? identityPublicKey,
  }) async {
    if (active.resuming) {
      return;
    }
    final reconnectedKey = identityPublicKey?.trim() ?? '';
    if (active.identityPublicKey.isEmpty ||
        reconnectedKey.isEmpty ||
        reconnectedKey != active.identityPublicKey) {
      FilesLog.write(
        'mount: $peerId identity mismatch on reconnect, unmounting',
      );
      await unmount(peerId);
      return;
    }
    active.resuming = true;
    final nextClient = RemoteFilesClient(peerId);
    try {
      final info = await nextClient.open(resume: true);
      if (!identical(_mounts[peerId], active)) {
        await nextClient.close();
        return;
      }
      final offeredRoots = {for (final root in info.roots) root.id};
      if (!info.canRead ||
          offeredRoots.isEmpty ||
          !active.rootIds.every(offeredRoots.contains)) {
        FilesLog.write(
          'mount: $peerId capabilities or roots changed on reconnect, unmounting',
        );
        await nextClient.close();
        await unmount(peerId);
        return;
      }
      active.cancelGrace();
      active.client = nextClient;
      active.source.rebind(
        nextClient,
        writable: info.canWrite && !info.readOnly,
        hasTrash: info.hasTrash,
      );
      _watchClientGone(peerId, active, nextClient);
      notifyListeners();
      FilesLog.write('mount: $peerId resumed after reconnect');
    } on RemoteFsException catch (error) {
      await nextClient.close();
      if (!identical(_mounts[peerId], active)) {
        return;
      }
      FilesLog.write(
        'mount: $peerId resume failed (${error.reason}), unmounting',
      );
      if (error.reason == 'denied' || error.reason == 'noAnswer') {
        await _remember(peerId, false);
      }
      await unmount(peerId);
    } finally {
      active.resuming = false;
    }
  }

  void _watchClientGone(
    String peerId,
    _Active active,
    RemoteFilesClient client,
  ) {
    unawaited(
      client.gone.then((error) {
        if (!identical(_mounts[peerId], active) ||
            !identical(active.client, client)) {
          return;
        }
        if (error.reason != 'offline') {
          FilesLog.write(
            'mount: $peerId ended (${error.reason}), unmounting immediately',
          );
          if (error.reason == 'denied' || error.reason == 'noAnswer') {
            unawaited(_remember(peerId, false));
          }
          unawaited(unmount(peerId));
          return;
        }
        if (gracePeriod <= Duration.zero) {
          FilesLog.write('mount: $peerId went away');
          unawaited(unmount(peerId));
          return;
        }
        FilesLog.write(
          'mount: $peerId disconnected, entering ${gracePeriod.inSeconds}s grace period',
        );
        active.source.suspend();
        active.cancelGrace();
        active.graceTimer = Timer(gracePeriod, () {
          if (identical(_mounts[peerId], active) && active.inGracePeriod) {
            FilesLog.write('mount: $peerId grace period expired, unmounting');
            unawaited(unmount(peerId));
          }
        });
        notifyListeners();
      }),
    );
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
    final customStarter = startMount;
    if (customStarter == null) {
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
    }
    final identityKey = peerIdentityKey?.call(peerId)?.trim() ?? '';
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
    final source = RemoteMountSource(
      client,
      writable: info.canWrite && !info.readOnly,
      hasTrash: info.hasTrash,
      reconnectWait: reconnectWait,
    );
    final _Active active;
    if (customStarter != null) {
      final started = await customStarter(source, roots, peerId, name);
      final mount = RemoteMount._(peerId, name, started.path);
      active = _Active(
        mount: mount,
        client: client,
        source: source,
        rootIds: {for (final r in roots) r.id},
        identityPublicKey: identityKey,
        stopWorker: started.stop,
        releaseOnDeath: started.stop,
        forgetPath: () async {},
      );
    } else {
      final place = await MountFrontend.prepare(peerId: peerId, name: name);
      if (place == null) {
        await client.close();
        throw const MountFailed(MountFailure.unsupported);
      }
      final MountWorker worker;
      try {
        worker = await MountWorker.start(
          source: source,
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
      active = _Active(
        mount: mount,
        client: client,
        source: source,
        rootIds: {for (final r in roots) r.id},
        identityPublicKey: identityKey,
        stopWorker: worker.stop,
        releaseOnDeath: () => MountFrontend.release(place.kind, mount.path),
        forgetPath: () => MountFrontend.forget(mount.path),
        worker: worker,
      );
      worker.onEnded = () => unawaited(_ended(peerId, active));
    }
    _mounts[peerId] = active;
    FilesLog.write('mount: ${roots.length} root(s) of $peerId mounted');
    _watchClientGone(peerId, active, client);
    return active.mount;
  }

  /// Ejected in the file manager: it stays off until turned on again.
  /// Its worker died instead: the mount goes, "挂载到本机" stays on.
  Future<void> _ended(String peerId, _Active active) async {
    if (!identical(_mounts[peerId], active)) {
      return;
    }
    _mounts.remove(peerId);
    active.cancelGrace();
    active.source.failSuspended();
    notifyListeners();
    final died = active.worker?.died ?? false;
    FilesLog.write(
      died
          ? 'mount: $peerId lost its worker'
          : 'mount: $peerId ejected in the file manager',
    );
    if (died) {
      await active.releaseOnDeath();
    } else {
      await active.stopWorker();
    }
    await active.client.close();
    await active.forgetPath();
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
    active.cancelGrace();
    active.source.failSuspended();
    notifyListeners();
    await active.stopWorker();
    await active.client.close();
    await active.forgetPath();
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
  _Active({
    required this.mount,
    required this.client,
    required this.source,
    required this.rootIds,
    required this.identityPublicKey,
    required this.stopWorker,
    required this.releaseOnDeath,
    required this.forgetPath,
    this.worker,
  });

  final RemoteMount mount;
  RemoteFilesClient client;
  final RemoteMountSource source;
  final Set<String> rootIds;
  final String identityPublicKey;
  final Future<void> Function() stopWorker;
  final Future<void> Function() releaseOnDeath;
  final Future<void> Function() forgetPath;
  final MountWorker? worker;
  Timer? graceTimer;
  bool resuming = false;

  bool get inGracePeriod => graceTimer != null;

  void cancelGrace() {
    graceTimer?.cancel();
    graceTimer = null;
  }
}
