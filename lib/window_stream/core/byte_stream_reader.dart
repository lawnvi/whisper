import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

class ByteStreamClosed implements Exception {
  const ByteStreamClosed();

  @override
  String toString() => 'ByteStreamClosed';
}

/// Pull-style reads (exact lengths, line-free) over a byte stream such as a
/// Socket. Pauses the source when too much is buffered.
class ByteStreamReader {
  ByteStreamReader(Stream<List<int>> source, {int maxBuffered = 4 << 20})
    : _maxBuffered = maxBuffered {
    _subscription = source.listen(
      _onData,
      onError: (Object error, StackTrace stack) {
        _error = error;
        _done = true;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  final int _maxBuffered;
  late final StreamSubscription<List<int>> _subscription;
  final _chunks = ListQueue<Uint8List>();
  int _headOffset = 0;
  int _available = 0;
  bool _done = false;
  Object? _error;
  Completer<void>? _waiter;

  int get available => _available;
  bool get isDone => _done && _available == 0;

  void _onData(List<int> data) {
    if (data.isEmpty) {
      return;
    }
    final chunk = data is Uint8List ? data : Uint8List.fromList(data);
    _chunks.add(chunk);
    _available += chunk.length;
    if (_available > _maxBuffered && !_subscription.isPaused) {
      _subscription.pause();
    }
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  Future<void> _waitForData() {
    // The caller needs more than is buffered, so the source must flow again
    // even if the buffer limit was hit.
    if (_subscription.isPaused) {
      _subscription.resume();
    }
    return (_waiter ??= Completer<void>()).future;
  }

  /// Reads exactly [length] bytes, or throws [ByteStreamClosed].
  Future<Uint8List> read(int length) async {
    while (_available < length) {
      if (_done) {
        final error = _error;
        if (error != null) {
          throw error;
        }
        throw const ByteStreamClosed();
      }
      await _waitForData();
    }
    return _take(length);
  }

  /// Returns the next buffered bytes (at most [maxLength]), or null at end.
  Future<Uint8List?> readSome([int maxLength = 1 << 20]) async {
    while (_available == 0) {
      if (_done) {
        final error = _error;
        if (error != null) {
          throw error;
        }
        return null;
      }
      await _waitForData();
    }
    final head = _chunks.first;
    final count = (head.length - _headOffset).clamp(0, maxLength);
    return _take(count);
  }

  /// Reads everything until the stream ends.
  Future<Uint8List> readToEnd() async {
    final builder = BytesBuilder(copy: false);
    while (true) {
      final chunk = await readSome();
      if (chunk == null) {
        return builder.takeBytes();
      }
      builder.add(chunk);
    }
  }

  Uint8List _take(int length) {
    if (length == 0) {
      return Uint8List(0);
    }
    final head = _chunks.first;
    if (head.length - _headOffset >= length) {
      final view = Uint8List.sublistView(
        head,
        _headOffset,
        _headOffset + length,
      );
      _headOffset += length;
      if (_headOffset == head.length) {
        _chunks.removeFirst();
        _headOffset = 0;
      }
      _available -= length;
      return view;
    }
    final out = Uint8List(length);
    var written = 0;
    while (written < length) {
      final chunk = _chunks.first;
      final take = (chunk.length - _headOffset).clamp(0, length - written);
      out.setRange(written, written + take, chunk, _headOffset);
      written += take;
      _headOffset += take;
      if (_headOffset == chunk.length) {
        _chunks.removeFirst();
        _headOffset = 0;
      }
    }
    _available -= length;
    return out;
  }

  Future<void> cancel() => _subscription.cancel();
}
