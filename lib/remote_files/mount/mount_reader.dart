import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'mount_tree.dart';

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
      final block = BytesBuilder(copy: false)..add(first);
      while (first.isNotEmpty && block.length < whole) {
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
      // Never more than the block holds: a read would not fit it.
      final data = block.takeBytes();
      return data.length > whole ? Uint8List.sublistView(data, 0, whole) : data;
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
