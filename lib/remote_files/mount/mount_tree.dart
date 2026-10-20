import 'dart:async';
import 'dart:collection';
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
  final int parent;
  final String name;

  /// The root it is in; empty for the top of a mount of several roots.
  final String root;

  /// Within [root], with `/` between folders; empty for the root itself.
  final String path;
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

  /// The top of a mount of several roots: not a folder over there.
  bool get isTop => root.isEmpty;
}

/// Why a mount operation failed, in the system's terms.
enum MountError { notFound, notDir, isDir, io, offline }

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
    final List<FsEntry> entries;
    try {
      entries = await source.list(folder.root, folder.path);
    } on MountException {
      rethrow;
    } catch (_) {
      throw const MountException(MountError.io);
    }
    final previous = {...?folder._children};
    final children = <int>[];
    for (final entry in entries) {
      if (entry.hidden && !showHiddenFiles && !entry.name.startsWith('.')) {
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
      .._children = children
      .._listedAt = _clock();
  }

  /// Reads part of a file through the block cache.
  Future<Uint8List> read(int ino, int offset, int length) {
    final node = _nodes[ino];
    if (node == null || node.gone) {
      throw const MountException(MountError.notFound);
    }
    if (node.isDir) {
      throw const MountException(MountError.isDir);
    }
    return reader.read(node, offset, length);
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

class _Block {
  _Block(this.generation);

  final int generation;
  late final Future<Uint8List> data;
  int bytes = 0;
}
