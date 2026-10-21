import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../fs_host_files.dart';

/// Where mount code logs: the app's files log, also from a worker isolate
/// (see MountWorker).
void Function(String line) mountLog = (_) {};

/// One of the other device's roots, as a top folder of its mount.
class MountRoot {
  const MountRoot({required this.id, required this.name});

  final String id;

  /// What the folder is called here ("C 盘", "内部存储").
  final String name;
}

/// Where a mount's files come from: the other device, or a folder here in
/// tests.
abstract class MountSource {
  /// Everything in a folder, hidden entries too.
  Future<List<FsEntry>> list(String root, String path);

  /// [length] bytes from [offset], fewer at the end of the file.
  Future<Uint8List> read(String root, String path, int offset, int length);

  /// Whether the device takes changes. When not, the mount is read-only
  /// and nothing below is asked.
  bool get writable => false;

  /// A new empty file.
  Future<FsEntry> create(String root, String parent, String name) =>
      _readOnly();

  Future<void> mkdir(String root, String parent, String name) => _readOnly();

  /// A file (to the trash there unless [permanent]), or an empty [folder].
  Future<void> remove(
    String root,
    String path, {
    bool folder = false,
    bool permanent = false,
  }) => _readOnly();

  /// Moves [path] to [name] in [parent], replacing a file there.
  Future<void> move(String root, String path, String parent, String name) =>
      _readOnly();

  Future<void> touch(String root, String path, int modifiedMs) => _readOnly();

  /// Its disk's size and free space, when the device says.
  Future<({int total, int free})?> space(String root) async => null;

  /// Starts writing an existing file, from what it holds or from nothing.
  Future<({String id, int size})> writeOpen(
    String root,
    String path, {
    required bool truncate,
  }) => _readOnly();

  Future<void> write(String upload, int offset, Uint8List data) => _readOnly();

  Future<void> writeSize(String upload, int size) => _readOnly();

  /// What [upload] holds so far.
  Future<Uint8List> readUpload(String upload, int offset, int length) =>
      _readOnly();

  /// Puts [upload] in its file's place ([commit]) or drops it; where it
  /// went (beside the file, if that changed there) and what it is now.
  Future<({String path, FsEntry? entry})> writeClose(
    String upload, {
    required bool commit,
    int? modifiedMs,
  }) => _readOnly();

  static Future<T> _readOnly<T>() =>
      Future.error(const MountException(MountError.readOnly));
}

/// A file or folder of a mount, numbered for the system (its inode).
class MountNode {
  MountNode._({
    required this.ino,
    required this.parent,
    required this.name,
    required this.root,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modifiedMs,
    this.hidden = false,
  });

  final int ino;

  /// Its folder and name, until it is moved.
  int parent;
  String name;

  /// The root it is in; empty for the top of a mount of several roots.
  final String root;

  /// Within [root], with `/` between folders; empty for the root itself.
  String path;
  final bool isDir;
  int size;
  int modifiedMs;
  bool hidden;

  /// Bumps when the file changed there, so what was read of it goes.
  int generation = 0;

  /// No longer there (the system may still hold on to it).
  bool gone = false;

  List<int>? _children;
  DateTime? _listedAt;
  Future<void>? _listing;

  /// Bumps when something in this folder is changed from here: a listing
  /// asked for before that may not have it yet.
  int _changes = 0;

  /// Changes made in this folder from here, which its time carries (in
  /// the nanoseconds, the device's own time staying as it is): a file
  /// system's folder changes time when something in it changes, and macOS
  /// trusts what it read of a folder (its listing) until it does, deciding
  /// from that whether `._name` is there to write an attribute to.
  int ticks = 0;

  /// The top of a mount of several roots: not a folder over there.
  bool get isTop => root.isEmpty;
}

/// Why a mount operation failed, in the system's terms.
enum MountError {
  notFound,
  notDir,
  isDir,
  io,
  offline,
  exists,
  notEmpty,

  /// The device lets this one read, not change; or it takes no changes.
  readOnly,

  /// Not something to change from here (the top of several roots).
  denied,

  /// A name the device's file system does not take.
  invalid,

  /// From one of the device's roots to another: copy, then delete.
  crossDevice,
}

class MountException implements Exception {
  const MountException(this.error);

  final MountError error;

  @override
  String toString() => 'MountException(${error.name})';
}

/// The other device's files as one tree for the system's file manager:
/// numbered nodes, folder listings kept for a few seconds, and file
/// contents read on demand in blocks through [MountReader].
class MountTree {
  MountTree(
    this.source,
    List<MountRoot> roots, {
    this.listingLifetime = const Duration(seconds: 3),
    this.showHiddenFiles = false,
    this.idleCommit,
    this.keepHere,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    final now = _clock().millisecondsSinceEpoch;
    if (roots.length == 1) {
      // One root: its folders are the mount's own.
      _add(
        rootIno,
        rootIno,
        '',
        roots.single.id,
        '',
        isDir: true,
        modifiedMs: now,
      );
    } else {
      final top = _add(
        rootIno,
        rootIno,
        '',
        '',
        '',
        isDir: true,
        modifiedMs: now,
      );
      top._children = [
        for (final root in roots)
          _add(
            _nextIno++,
            rootIno,
            _safeName(root.name),
            root.id,
            '',
            isDir: true,
            modifiedMs: now,
          ).ino,
      ];
      top._listedAt = DateTime.utc(9999);
    }
    reader = MountReader(this);
  }

  static const rootIno = 1;

  final MountSource source;
  final Duration listingLifetime;

  /// Windows' hidden files (NTUSER.DAT, desktop.ini): only a system that
  /// can hide them gets them. Names starting with a dot always come, as
  /// file managers hide those themselves.
  final bool showHiddenFiles;
  final DateTime Function() _clock;
  late final MountReader reader;
  final _nodes = <int, MountNode>{};
  final _byPath = <String, int>{};
  int _nextIno = 2;

  /// A file written to and left alone this long is put in place: for a
  /// system that never says it is done with a file (NFS writes that ask
  /// for no commit). Null: only [commit] does.
  final Duration? idleCommit;

  final _uploads = <int, _Upload>{};

  /// Names of files kept in this mount only, never put on the device:
  /// what macOS writes beside each file on a disk without extended
  /// attributes (`._name`) and Finder's folder settings (`.DS_Store`).
  /// Those on the device are not shown.
  final bool Function(String name)? keepHere;

  /// What files [keepHere] holds, by node.
  final _kept = <int, Uint8List>{};
  int _keptBytes = 0;
  static const _mostKept = 64 * 1024 * 1024;

  /// Files made through this mount: deleting them deletes them for good,
  /// where what was there before goes to the device's trash.
  final _madeHere = <int>{};

  /// An idle commit that failed, told to the next [commit] of the file.
  final _failed = <int, MountException>{};

  ({int total, int free})? _space;
  DateTime? _spaceAt;

  /// The device takes changes.
  bool get writable => source.writable;

  MountNode get top => _nodes[rootIno]!;

  MountNode? node(int ino) => _nodes[ino];

  MountNode _add(
    int ino,
    int parent,
    String name,
    String root,
    String path, {
    required bool isDir,
    int size = 0,
    int modifiedMs = 0,
    bool hidden = false,
  }) {
    final node = MountNode._(
      ino: ino,
      parent: parent,
      name: name,
      root: root,
      path: path,
      isDir: isDir,
      size: size,
      modifiedMs: modifiedMs,
      hidden: hidden,
    );
    _nodes[ino] = node;
    _byPath['$root\u0000$path'] = ino;
    return node;
  }

  /// A folder's entries, listed again once [listingLifetime] passed.
  Future<List<MountNode>> children(int ino) async {
    final folder = _nodes[ino];
    if (folder == null || folder.gone) {
      throw const MountException(MountError.notFound);
    }
    if (!folder.isDir) {
      throw const MountException(MountError.notDir);
    }
    final listedAt = folder._listedAt;
    if (listedAt == null || _clock().difference(listedAt) > listingLifetime) {
      await (folder._listing ??= _list(
        folder,
      ).whenComplete(() => folder._listing = null));
    }
    return [
      for (final child in folder._children ?? const <int>[])
        if (_nodes[child] case final node? when !node.gone) node,
    ];
  }

  /// [name] in folder [parent], or null when there is none.
  Future<MountNode?> lookup(int parent, String name) async {
    if (keepHere?.call(name) ?? false) {
      // Never on the device, so nothing to ask it: macOS looks for `._name`
      // at every look at a file's attributes, slow network or not.
      final folder = _nodes[parent];
      if (folder == null || folder.gone) {
        throw const MountException(MountError.notFound);
      }
      for (final ino in _kept.keys) {
        final node = _nodes[ino];
        if (node != null &&
            !node.gone &&
            node.parent == parent &&
            node.name == name) {
          return node;
        }
      }
      return null;
    }
    for (final child in await children(parent)) {
      if (child.name == name) {
        return child;
      }
    }
    return null;
  }

  /// [ino] with what its folder said of it lately.
  Future<MountNode> stat(int ino) async {
    final node = _nodes[ino];
    if (node == null || node.gone) {
      throw const MountException(MountError.notFound);
    }
    if (_kept.containsKey(ino)) {
      return node;
    }
    final folder = _nodes[node.parent];
    if (!node.isDir && folder != null && !folder.isTop) {
      // Its folder's listing carries its size; keep that fresh.
      await children(node.parent);
      if (node.gone) {
        throw const MountException(MountError.notFound);
      }
    }
    return node;
  }

  Future<void> _list(MountNode folder) async {
    List<FsEntry> entries;
    for (var attempt = 0; ; attempt++) {
      final changes = folder._changes;
      try {
        entries = await source.list(folder.root, folder.path);
      } on MountException {
        rethrow;
      } catch (_) {
        throw const MountException(MountError.io);
      }
      // Changed from here while it was asked for: this listing may not
      // have the change yet.
      if (folder._changes == changes) {
        break;
      }
      if (attempt == 2) {
        folder._listedAt = null;
        return;
      }
    }
    final previous = {...?folder._children};
    final kept = [
      for (final ino in previous)
        if (_kept.containsKey(ino) && _nodes[ino]?.gone == false) ino,
    ];
    previous.removeAll(kept);
    final children = <int>[];
    for (final entry in entries) {
      if (entry.hidden && !showHiddenFiles && !entry.name.startsWith('.')) {
        continue;
      }
      if (keepHere?.call(entry.name) ?? false) {
        continue;
      }
      final name = _safeName(entry.name);
      if (name != entry.name) {
        // Not a name the system can show; its real name is not ours to
        // change.
        continue;
      }
      final path = folder.path.isEmpty ? name : '${folder.path}/$name';
      final known = _byPath['${folder.root}\u0000$path'];
      final existing = known == null ? null : _nodes[known];
      if (existing != null &&
          existing.isDir == entry.isDir &&
          _uploads.containsKey(existing.ino)) {
        // Being written here: what it holds here goes.
        existing.gone = false;
        children.add(existing.ino);
        previous.remove(existing.ino);
        continue;
      }
      if (existing != null && existing.isDir == entry.isDir) {
        if (existing.size != entry.size ||
            existing.modifiedMs != entry.modifiedMs) {
          existing.generation++;
          reader.forget(existing.ino);
        }
        existing
          ..size = entry.size
          ..modifiedMs = entry.modifiedMs
          ..hidden = entry.hidden
          ..gone = false;
        children.add(existing.ino);
        previous.remove(existing.ino);
        continue;
      }
      if (existing != null) {
        existing.gone = true;
        reader.forget(existing.ino);
      }
      children.add(
        _add(
          _nextIno++,
          folder.ino,
          name,
          folder.root,
          path,
          isDir: entry.isDir,
          size: entry.isDir ? 0 : entry.size,
          modifiedMs: entry.modifiedMs,
          hidden: entry.hidden,
        ).ino,
      );
    }
    for (final removed in previous) {
      _nodes[removed]?.gone = true;
      reader.forget(removed);
    }
    folder
      .._children = [...children, ...kept]
      .._listedAt = _clock();
  }

  /// Reads part of a file through the block cache; one being written,
  /// from what was written.
  Future<Uint8List> read(int ino, int offset, int length) async {
    final node = _nodes[ino];
    if (node == null || node.gone) {
      throw const MountException(MountError.notFound);
    }
    if (node.isDir) {
      throw const MountException(MountError.isDir);
    }
    if (_kept[ino] case final data?) {
      final end = min(offset + length, data.length);
      return offset >= end
          ? Uint8List(0)
          : Uint8List.fromList(Uint8List.sublistView(data, offset, end));
    }
    final upload = await _settled(ino);
    if (upload == null) {
      return reader.read(node, offset, length);
    }
    await _drain(upload);
    final opened = await upload.opened;
    final end = min(offset + length, upload.size);
    if (offset >= end) {
      return Uint8List(0);
    }
    return _guard(source.readUpload(opened.id, offset, end - offset));
  }

  // Changes. Writes go to the device as they come, a file's at a time in
  // order, up to [_inFlight] bytes ahead of what it has taken; small ones
  // in a row go together. What fails is told by the next write, or by
  // [commit], which waits for all of it and puts the file in place.

  static const _chunk = 1024 * 1024;
  static const _inFlight = 8 * 1024 * 1024;

  /// A new empty file [name] in folder [parent].
  Future<MountNode> create(int parent, String name) async {
    final folder = await _changeable(parent);
    if (await lookup(parent, name) != null) {
      throw const MountException(MountError.exists);
    }
    if (keepHere?.call(name) ?? false) {
      final node = _place(
        folder,
        FsEntry(
          name: name,
          isDir: false,
          size: 0,
          modifiedMs: _clock().millisecondsSinceEpoch,
        ),
      );
      _kept[node.ino] = Uint8List(0);
      _changed(folder);
      return node;
    }
    _changed(folder);
    final entry = await _guard(source.create(folder.root, folder.path, name));
    final node = _place(folder, entry);
    _madeHere.add(node.ino);
    return node;
  }

  /// [ino] kept here now holds [data].
  void _keep(MountNode node, Uint8List data) {
    final before = _kept[node.ino]?.length ?? 0;
    if (_keptBytes - before + data.length > _mostKept) {
      throw const MountException(MountError.io);
    }
    _keptBytes += data.length - before;
    _kept[node.ino] = data;
    node
      ..size = data.length
      ..modifiedMs = _clock().millisecondsSinceEpoch;
  }

  Future<MountNode> mkdir(int parent, String name) async {
    final folder = await _changeable(parent);
    if (await lookup(parent, name) != null) {
      throw const MountException(MountError.exists);
    }
    _changed(folder);
    await _guard(source.mkdir(folder.root, folder.path, name));
    final node = _place(
      folder,
      FsEntry(
        name: name,
        isDir: true,
        size: 0,
        modifiedMs: _clock().millisecondsSinceEpoch,
      ),
    );
    _madeHere.add(node.ino);
    return node;
  }

  /// Deletes file [name]: for good if it was made here, else to the
  /// device's trash.
  Future<void> unlink(int parent, String name) async {
    final folder = await _changeable(parent);
    final node = await lookup(parent, name);
    if (node == null) {
      throw const MountException(MountError.notFound);
    }
    if (node.isDir) {
      throw const MountException(MountError.isDir);
    }
    if (_kept.containsKey(node.ino)) {
      _drop(node);
      _changed(folder);
      return;
    }
    await _discard(node.ino);
    _changed(folder);
    await _guard(
      source.remove(
        node.root,
        node.path,
        permanent: _madeHere.contains(node.ino),
      ),
    );
    _drop(node);
  }

  /// Deletes [name], a file or a whole folder with all in it (moved to
  /// the Recycle Bin, say): a file made here for good, anything else to
  /// the device's trash.
  Future<void> remove(int parent, String name) async {
    final folder = await _changeable(parent);
    final node = await lookup(parent, name);
    if (node == null) {
      throw const MountException(MountError.notFound);
    }
    if (_kept.containsKey(node.ino)) {
      _drop(node);
      _changed(folder);
      return;
    }
    final under = [
      for (final other in _nodes.values)
        if (other.root == node.root &&
            (other.path == node.path || other.path.startsWith('${node.path}/')))
          other,
    ];
    for (final other in under) {
      await _discard(other.ino);
    }
    _changed(folder);
    // A folder made here may hold what was there before (moved in): it
    // goes to the trash all the same.
    await _guard(
      source.remove(
        node.root,
        node.path,
        permanent: !node.isDir && _madeHere.contains(node.ino),
      ),
    );
    for (final other in under) {
      _drop(other);
    }
  }

  /// Removes folder [name], which must be empty.
  Future<void> rmdir(int parent, String name) async {
    final folder = await _changeable(parent);
    final node = await lookup(parent, name);
    if (node == null) {
      throw const MountException(MountError.notFound);
    }
    if (!node.isDir) {
      throw const MountException(MountError.notDir);
    }
    _changed(folder);
    await _guard(source.remove(node.root, node.path, folder: true));
    for (final child in _nodes.values.toList()) {
      if (child.parent == node.ino && _kept.containsKey(child.ino)) {
        _drop(child);
      }
    }
    _drop(node);
  }

  /// Moves [name] in [parent] to [newName] in [newParent], replacing what
  /// is there as a rename does, unless [noReplace]. Within one of the
  /// device's roots only.
  Future<void> rename(
    int parent,
    String name,
    int newParent,
    String newName, {
    bool noReplace = false,
  }) async {
    final from = await _changeable(parent);
    final to = await _changeable(newParent);
    final node = await lookup(parent, name);
    if (node == null) {
      throw const MountException(MountError.notFound);
    }
    if (to.root != node.root) {
      throw const MountException(MountError.crossDevice);
    }
    final existing = await lookup(newParent, newName);
    if (identical(existing, node)) {
      return;
    }
    final keptHere = _kept.containsKey(node.ino);
    if (keptHere || (keepHere?.call(newName) ?? false)) {
      // Kept here to kept here only: neither goes to the device.
      if (!keptHere ||
          !(keepHere?.call(newName) ?? false) ||
          (existing != null && !_kept.containsKey(existing.ino))) {
        throw const MountException(MountError.denied);
      }
      if (existing != null) {
        if (noReplace) {
          throw const MountException(MountError.exists);
        }
        _drop(existing);
      }
      _move(node, to, newName);
      _changed(from);
      _changed(to);
      return;
    }
    if (existing != null) {
      if (noReplace) {
        throw const MountException(MountError.exists);
      }
      if (existing.isDir && !node.isDir) {
        throw const MountException(MountError.isDir);
      }
      if (!existing.isDir && node.isDir) {
        throw const MountException(MountError.notDir);
      }
    }
    // What is being written goes where it was first: its writes are put
    // in place before it moves.
    for (final upload in _uploads.values.toList()) {
      final path = upload.node.path;
      if (upload.node.root == node.root &&
          (path == node.path || path.startsWith('${node.path}/'))) {
        await commit(upload.node.ino);
      }
    }
    if (existing != null) {
      await _discard(existing.ino);
    }
    _changed(from);
    _changed(to);
    await _guard(source.move(node.root, node.path, to.path, newName));
    if (existing != null) {
      _drop(existing);
    }
    _move(node, to, newName);
  }

  /// Sets a file's modification time (with its other changes, if it is
  /// being written). Folders keep theirs.
  Future<void> setModified(int ino, int modifiedMs) async {
    final node = await _changeableNode(ino);
    if (node.isDir) {
      return;
    }
    final upload = await _settled(ino);
    if (_kept.containsKey(ino)) {
      // Kept here: only here.
    } else if (upload != null) {
      upload.modifiedMs = modifiedMs;
    } else {
      await _guard(source.touch(node.root, node.path, modifiedMs));
    }
    node.modifiedMs = modifiedMs;
  }

  /// Makes a file [size] bytes long.
  Future<void> resize(int ino, int size) async {
    final node = await _changeableNode(ino);
    if (node.isDir) {
      throw const MountException(MountError.isDir);
    }
    if (_kept[ino] case final data?) {
      _keep(
        node,
        size <= data.length
            ? Uint8List.fromList(Uint8List.sublistView(data, 0, size))
            : (Uint8List(size)..setAll(0, data)),
      );
      return;
    }
    final existing = await _settled(ino);
    if (existing == null && size == 0) {
      // Opened to be written anew: nothing of what it holds is copied.
      await _uploadOf(node, truncate: true);
      node
        ..size = 0
        ..modifiedMs = _clock().millisecondsSinceEpoch;
      return;
    }
    if (existing == null && size == node.size) {
      return;
    }
    final upload = existing ?? await _uploadOf(node, truncate: false);
    await _drain(upload);
    final opened = await upload.opened;
    await _guard(source.writeSize(opened.id, size));
    upload.size = size;
    node
      ..size = size
      ..modifiedMs = _clock().millisecondsSinceEpoch;
    _idle(upload);
  }

  /// Writes [data] at [offset]; failing, it or a later write says so.
  Future<void> write(int ino, int offset, Uint8List data) async {
    final node = await _changeableNode(ino);
    if (node.isDir) {
      throw const MountException(MountError.isDir);
    }
    if (_kept[ino] case final held?) {
      _keep(
        node,
        Uint8List(max(held.length, offset + data.length))
          ..setAll(0, held)
          ..setAll(offset, data),
      );
      return;
    }
    final upload = await _uploadOf(node, truncate: false);
    upload.check();
    if (upload.pending.isNotEmpty &&
        offset == upload.pendingAt + upload.pending.length &&
        upload.pending.length + data.length <= _chunk) {
      upload.pending.add(data);
    } else {
      _send(upload);
      var at = 0;
      while (data.length - at >= _chunk) {
        _sendBytes(
          upload,
          offset + at,
          Uint8List.fromList(Uint8List.sublistView(data, at, at + _chunk)),
        );
        at += _chunk;
      }
      if (at < data.length) {
        upload.pendingAt = offset + at;
        upload.pending.add(Uint8List.sublistView(data, at));
      }
    }
    if (upload.pending.length >= _chunk) {
      _send(upload);
    }
    final end = offset + data.length;
    if (end > upload.size) {
      upload.size = end;
    }
    node
      ..size = upload.size
      ..modifiedMs = _clock().millisecondsSinceEpoch;
    while (upload.inFlightBytes > _inFlight && upload.inFlight.isNotEmpty) {
      await Future.any(upload.inFlight);
    }
    upload.check();
    _idle(upload);
  }

  /// Puts what was written to [ino] in place on the device; tells what
  /// went wrong with it, if anything did.
  Future<void> commit(int ino) async {
    final upload = _uploads[ino];
    final failed = _failed.remove(ino);
    if (failed != null) {
      // Some of what was written never got there: what did is not put in
      // place as if it were the file.
      if (upload != null && upload.closing == null) {
        await _discard(ino);
      }
      throw failed;
    }
    if (upload == null) {
      return;
    }
    return upload.closing ??= _commit(upload);
  }

  /// Everything written to [ino] so far has reached the device (not yet
  /// in place there: [commit] does that).
  Future<void> settle(int ino) async {
    final upload = await _settled(ino);
    if (upload != null) {
      await _drain(upload);
    }
  }

  Future<void> _commit(_Upload upload) async {
    upload.idle?.cancel();
    final node = upload.node;
    try {
      final opened = await upload.opened;
      try {
        await _drain(upload);
      } catch (_) {
        unawaited(
          source
              .writeClose(opened.id, commit: false)
              .then((_) {}, onError: (Object _) {}),
        );
        rethrow;
      }
      final folder = _nodes[node.parent];
      _changed(folder);
      final closed = await _guard(
        source.writeClose(
          opened.id,
          commit: true,
          modifiedMs: upload.modifiedMs,
        ),
      );
      final entry = closed.entry;
      if (entry != null && closed.path == node.path) {
        node
          ..size = entry.size
          ..modifiedMs = entry.modifiedMs;
      } else {
        // Kept beside the file, which changed there meanwhile: the file is
        // what it is there, and the copy shows with the next listing.
        folder?._listedAt = null;
      }
      node.generation++;
      reader.forget(node.ino);
    } finally {
      if (identical(_uploads[node.ino], upload)) {
        _uploads.remove(node.ino);
      }
    }
  }

  /// Drops what was written to [ino] and not put in place.
  Future<void> _discard(int ino) async {
    final upload = _uploads.remove(ino);
    if (upload == null) {
      return;
    }
    upload.idle?.cancel();
    try {
      final opened = await upload.opened;
      await Future.wait(upload.inFlight.toList());
      await source.writeClose(opened.id, commit: false);
    } catch (_) {
      // Gone with the file all the same.
    }
  }

  /// The disk's size and free space, as the device last said (asked
  /// again after half a minute).
  Future<({int total, int free})> space() async {
    final at = _spaceAt;
    final known = _space;
    if (known != null &&
        at != null &&
        _clock().difference(at) < const Duration(seconds: 30)) {
      return known;
    }
    final root = top.isTop
        ? (top._children ?? const <int>[])
              .map((ino) => _nodes[ino]?.root)
              .whereType<String>()
              .firstOrNull
        : top.root;
    ({int total, int free})? space;
    if (root != null) {
      try {
        space = await source.space(root);
      } catch (_) {
        // Said as unknown below.
      }
    }
    _spaceAt = _clock();
    return _space = space ?? (total: 1 << 50, free: 1 << 49);
  }

  /// [ino]'s upload once any commit of it is done: writes after a commit
  /// begin anew.
  Future<_Upload?> _settled(int ino) async {
    var upload = _uploads[ino];
    while (upload != null && upload.closing != null) {
      try {
        await upload.closing;
      } catch (_) {
        // Told to whoever committed.
      }
      upload = _uploads[ino];
    }
    return upload;
  }

  Future<_Upload> _uploadOf(MountNode node, {required bool truncate}) async {
    while (true) {
      final existing = await _settled(node.ino);
      if (existing != null) {
        return existing;
      }
      // Another write may have begun one while this waited.
      if (_uploads[node.ino] == null) {
        break;
      }
    }
    // One made here and still empty has nothing to copy.
    truncate |= node.size == 0 && _madeHere.contains(node.ino);
    final upload = _Upload(
      node,
      _guard(source.writeOpen(node.root, node.path, truncate: truncate)),
      truncate ? 0 : node.size,
    );
    _uploads[node.ino] = upload;
    try {
      final opened = await upload.opened;
      if (!truncate && upload.size == node.size) {
        upload.size = max(upload.size, opened.size);
      }
    } catch (error) {
      if (identical(_uploads[node.ino], upload)) {
        _uploads.remove(node.ino);
      }
      // Writes that went along with it are lost: closing the file says so.
      _failed[node.ino] = error is MountException
          ? error
          : const MountException(MountError.io);
      rethrow;
    }
    return upload;
  }

  /// Sends what [upload] holds back.
  void _send(_Upload upload) {
    if (upload.pending.isEmpty) {
      return;
    }
    final at = upload.pendingAt;
    final bytes = upload.pending.takeBytes();
    _sendBytes(upload, at, bytes);
  }

  void _sendBytes(_Upload upload, int offset, Uint8List bytes) {
    late final Future<void> sent;
    sent = upload.opened
        .then((opened) => source.write(opened.id, offset, bytes))
        .then(
          (_) {},
          onError: (Object error) {
            upload.failed ??= error is MountException
                ? error
                : const MountException(MountError.io);
          },
        )
        .whenComplete(() {
          upload.inFlight.remove(sent);
          upload.inFlightBytes -= bytes.length;
        });
    upload.inFlight.add(sent);
    upload.inFlightBytes += bytes.length;
  }

  /// Everything written to [upload] has reached the device.
  Future<void> _drain(_Upload upload) async {
    _send(upload);
    while (upload.inFlight.isNotEmpty) {
      await Future.wait(upload.inFlight.toList());
    }
    upload.check();
  }

  void _idle(_Upload upload) {
    final after = idleCommit;
    if (after == null) {
      return;
    }
    upload.idle?.cancel();
    upload.idle = Timer(after, () {
      if (!identical(_uploads[upload.node.ino], upload) ||
          upload.closing != null) {
        return;
      }
      final ino = upload.node.ino;
      commit(ino).catchError((Object error) {
        mountLog('mount: putting a file in place failed: $error');
        _failed[ino] = error is MountException
            ? error
            : const MountException(MountError.io);
      });
    });
  }

  Future<MountNode> _changeable(int ino) async {
    final node = await _changeableNode(ino);
    if (!node.isDir) {
      throw const MountException(MountError.notDir);
    }
    return node;
  }

  Future<MountNode> _changeableNode(int ino) async {
    final node = _nodes[ino];
    if (node == null || node.gone) {
      throw const MountException(MountError.notFound);
    }
    if (!writable) {
      throw const MountException(MountError.readOnly);
    }
    if (node.isTop) {
      throw const MountException(MountError.denied);
    }
    return node;
  }

  /// [entry], new in [folder], as a node there.
  MountNode _place(MountNode folder, FsEntry entry) {
    final path = folder.path.isEmpty
        ? entry.name
        : '${folder.path}/${entry.name}';
    final known = _byPath['${folder.root}\u0000$path'];
    final existing = known == null ? null : _nodes[known];
    final MountNode node;
    // Never one that was deleted: the system may still hold its number for
    // the file that went (NFS takes a handle it saw removed for gone, and
    // macOS then fails writing extended attributes beside it).
    if (existing != null && !existing.gone && existing.isDir == entry.isDir) {
      node = existing
        ..size = entry.size
        ..modifiedMs = entry.modifiedMs
        ..gone = false
        ..generation += 1;
      reader.forget(node.ino);
    } else {
      existing?.gone = true;
      node = _add(
        _nextIno++,
        folder.ino,
        entry.name,
        folder.root,
        path,
        isDir: entry.isDir,
        size: entry.isDir ? 0 : entry.size,
        modifiedMs: entry.modifiedMs,
      );
    }
    final children = folder._children;
    if (children != null && !children.contains(node.ino)) {
      children.add(node.ino);
    }
    return node;
  }

  void _drop(MountNode node) {
    node.gone = true;
    final key = '${node.root}\u0000${node.path}';
    if (_byPath[key] == node.ino) {
      // Made again later, it is another file with a number of its own.
      _byPath.remove(key);
    }
    reader.forget(node.ino);
    _madeHere.remove(node.ino);
    _keptBytes -= _kept.remove(node.ino)?.length ?? 0;
    _nodes[node.parent]?._children?.remove(node.ino);
  }

  /// [node] (and all under it) is now [name] in [to].
  void _move(MountNode node, MountNode to, String name) {
    _nodes[node.parent]?._children?.remove(node.ino);
    final from = node.path;
    final path = to.path.isEmpty ? name : '${to.path}/$name';
    final moved = [
      for (final other in _nodes.values)
        if (other.root == node.root &&
            (other.path == from || other.path.startsWith('$from/')))
          other,
    ];
    for (final other in moved) {
      if (_byPath['${other.root}\u0000${other.path}'] == other.ino) {
        _byPath.remove('${other.root}\u0000${other.path}');
      }
    }
    for (final other in moved) {
      other.path = path + other.path.substring(from.length);
      _byPath['${other.root}\u0000${other.path}'] = other.ino;
    }
    node
      ..parent = to.ino
      ..name = name;
    final children = to._children;
    if (children != null && !children.contains(node.ino)) {
      children.add(node.ino);
    }
  }

  void _changed(MountNode? folder) {
    if (folder == null) {
      return;
    }
    folder._changes++;
    folder.ticks++;
  }

  static Future<T> _guard<T>(Future<T> work) async {
    try {
      return await work;
    } on MountException {
      rethrow;
    } catch (_) {
      throw const MountException(MountError.io);
    }
  }

  /// Folder names can't hold `/`, and NUL ends a name everywhere.
  static String _safeName(String name) =>
      name.replaceAll('/', '∕').replaceAll('\u0000', '');
}

/// File contents in [blockSize] blocks: each read asks the other device
/// only for blocks not already here, reading on ahead while a file is read
/// from start to end.
class MountReader {
  MountReader(this.tree, {this.maxCached = 128 * 1024 * 1024});

  static const blockSize = 1024 * 1024;
  static const _maxAhead = 8;
  static const _maxRunning = 8;

  final MountTree tree;
  final int maxCached;

  final _blocks = <(int, int), _Block>{};
  int _cachedBytes = 0;
  final _ahead = <int, ({int end, int window})>{};
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<Uint8List> read(MountNode node, int offset, int length) async {
    if (offset >= node.size || length <= 0) {
      return Uint8List(0);
    }
    final end = (offset + length).clamp(0, node.size);
    final first = offset ~/ blockSize;
    final last = (end - 1) ~/ blockSize;
    final blocks = [
      for (var index = first; index <= last; index++) _block(node, index),
    ];
    _readAhead(node, offset, end, last);
    final out = Uint8List(end - offset);
    var at = 0;
    for (var i = 0; i < blocks.length; i++) {
      final data = await blocks[i].data;
      final blockStart = (first + i) * blockSize;
      final from = (i == 0 ? offset - blockStart : 0).clamp(0, data.length);
      final to = (end - blockStart).clamp(from, data.length);
      out.setRange(at, at + to - from, data, from);
      at += to - from;
      if (data.length < blockSize && i < blocks.length - 1) {
        // The file is shorter there than it said.
        return Uint8List.sublistView(out, 0, at);
      }
    }
    return at == out.length ? out : Uint8List.sublistView(out, 0, at);
  }

  /// Read from start to end: fetch the blocks after this one before they
  /// are asked for, more of them the longer it goes on.
  void _readAhead(MountNode node, int offset, int end, int last) {
    final previous = _ahead[node.ino];
    final sequential =
        previous != null &&
        offset >= previous.end - blockSize &&
        offset <= previous.end + blockSize;
    final window = sequential
        ? (previous.window * 2).clamp(1, _maxAhead)
        : (offset == 0 ? 1 : 0);
    _ahead[node.ino] = (end: end, window: window);
    final blocksInFile = (node.size + blockSize - 1) ~/ blockSize;
    for (var index = last + 1; index <= last + window; index++) {
      if (index >= blocksInFile) {
        break;
      }
      final block = _block(node, index);
      // Nobody waits for these yet: a failure is only seen when they are.
      block.data.ignore();
    }
  }

  _Block _block(MountNode node, int index) {
    final key = (node.ino, index);
    final cached = _blocks.remove(key);
    if (cached != null && cached.generation == node.generation) {
      _blocks[key] = cached;
      return cached;
    }
    if (cached != null) {
      _cachedBytes -= cached.bytes;
    }
    final block = _Block(node.generation);
    _blocks[key] = block;
    block.data = _fetch(node, index).then(
      (data) {
        block.bytes = data.length;
        if (identical(_blocks[key], block)) {
          _cachedBytes += data.length;
          _trim();
        }
        return data;
      },
      onError: (Object error) {
        if (identical(_blocks[key], block)) {
          _blocks.remove(key);
        }
        throw error;
      },
    );
    return block;
  }

  Future<Uint8List> _fetch(MountNode node, int index) async {
    if (_running >= _maxRunning) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      final start = index * blockSize;
      final first = await tree.source.read(
        node.root,
        node.path,
        start,
        blockSize,
      );
      // A device may send less than asked before the end (read() on a
      // phone's shared storage returns early): ask on for the rest, or
      // the rest of the block would be served as nothing.
      final whole = (node.size - start).clamp(0, blockSize);
      if (first.isEmpty || first.length >= whole) {
        return first;
      }
      final block = BytesBuilder(copy: false)..add(first);
      while (block.length < whole) {
        final more = await tree.source.read(
          node.root,
          node.path,
          start + block.length,
          blockSize - block.length,
        );
        if (more.isEmpty) {
          break; // it ends there now
        }
        block.add(more);
      }
      return block.takeBytes();
    } on MountException {
      rethrow;
    } catch (_) {
      throw const MountException(MountError.io);
    } finally {
      _running--;
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      }
    }
  }

  void _trim() {
    while (_cachedBytes > maxCached && _blocks.isNotEmpty) {
      final oldest = _blocks.keys.first;
      _cachedBytes -= _blocks.remove(oldest)!.bytes;
    }
  }

  /// [ino] changed or went: what was read of it is no longer good.
  void forget(int ino) {
    _ahead.remove(ino);
    _blocks.removeWhere((key, block) {
      if (key.$1 == ino) {
        _cachedBytes -= block.bytes;
        return true;
      }
      return false;
    });
  }
}

/// A file being written: one upload on the device, and what is on its way.
class _Upload {
  _Upload(this.node, this.opened, this.size) {
    // Its failure is told to whoever waits on it.
    opened.ignore();
  }

  final MountNode node;
  final Future<({String id, int size})> opened;

  /// How long the file is as written here.
  int size;

  /// To be its modification time once in place.
  int? modifiedMs;

  /// Small writes in a row, sent together.
  final pending = BytesBuilder();
  int pendingAt = 0;

  final inFlight = <Future<void>>[];
  int inFlightBytes = 0;
  MountException? failed;
  Future<void>? closing;
  Timer? idle;

  void check() {
    final error = failed;
    if (error != null) {
      throw error;
    }
  }
}

class _Block {
  _Block(this.generation);

  final int generation;
  late final Future<Uint8List> data;
  int bytes = 0;
}
