import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

/// Bytes the host media isolate sealed for a `/window` socket that only the
/// main isolate holds. [bytes] null closes the socket after what came
/// before it.
final class RelayWrite {
  const RelayWrite(this.link, this.seq, this.bytes);

  final int link;
  final int seq;
  final TransferableTypedData? bytes;
}

/// The main isolate's answer to write [seq] on [link]. Not [ok] fails every
/// write waiting on that link and every later one: the socket is gone.
final class RelayAck {
  const RelayAck(this.link, this.seq, {required this.ok});

  final int link;
  final int seq;
  final bool ok;
}

class RelayedSocketGone implements Exception {
  const RelayedSocketGone();

  @override
  String toString() => 'RelayedSocketGone';
}

/// The media isolate's end: `addStream` and close for a transport whose
/// socket is in the main isolate. A write completes only once the socket
/// took it there, so the transport's queue feels the socket's backpressure
/// as if it held the socket itself. The transport writes one at a time.
class RelayedWriter {
  RelayedWriter(this.link, this._send);

  final int link;
  final void Function(Object message) _send;
  final _waiting = <int, Completer<void>>{};
  int _seq = 0;
  bool _failed = false;

  Future<void> addStream(Stream<Object> stream) async {
    await for (final chunk in stream) {
      await _write(TransferableTypedData.fromList([_bytes(chunk)]));
    }
  }

  Future<void> close() => _write(null);

  Future<void> _write(TransferableTypedData? bytes) {
    if (_failed) {
      return Future<void>.error(const RelayedSocketGone());
    }
    final seq = ++_seq;
    final done = _waiting[seq] = Completer<void>();
    _send(RelayWrite(link, seq, bytes));
    return done.future;
  }

  void answer(RelayAck ack) {
    if (ack.ok) {
      _waiting.remove(ack.seq)?.complete();
      return;
    }
    _failed = true;
    final waiting = _waiting.values.toList(growable: false);
    _waiting.clear();
    for (final done in waiting) {
      done.completeError(const RelayedSocketGone());
    }
  }

  static TypedData _bytes(Object chunk) => switch (chunk) {
    final TypedData data => data,
    final List<int> list => Uint8List.fromList(list),
    _ => throw ArgumentError.value(chunk, 'chunk', 'not bytes'),
  };
}

/// The main isolate's end: writes what a [RelayedWriter] sends, in order,
/// and answers each once the socket took it. The moment the socket closes
/// or a write fails, the isolate hears it: nothing waits for a timeout.
class RelayedSink {
  RelayedSink(this.link, this._sink, this._answer) {
    unawaited(
      _sink.done.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (!_closing) fail();
      }),
    );
  }

  final int link;
  final StreamSink<dynamic> _sink;
  final void Function(Object message) _answer;
  Future<void> _tail = Future<void>.value();
  bool _gone = false;
  bool _closing = false;

  void take(RelayWrite write) {
    _tail = _tail.then((_) => _write(write));
  }

  Future<void> _write(RelayWrite write) async {
    if (_gone) {
      return;
    }
    try {
      final bytes = write.bytes;
      if (bytes == null) {
        _closing = true;
        await _sink.close();
      } else {
        await _sink.addStream(
          Stream<Object>.value(bytes.materialize().asUint8List()),
        );
      }
      _answer(RelayAck(link, write.seq, ok: true));
    } catch (_) {
      fail();
    }
  }

  /// The socket is gone: every write the isolate waits on fails now.
  void fail() {
    if (_gone) {
      return;
    }
    _gone = true;
    _answer(RelayAck(link, 0, ok: false));
  }

  /// Closes the socket here, whatever the isolate did.
  Future<void> closeSocket() {
    _closing = true;
    fail();
    return _sink.close().then<void>((_) {}, onError: (Object _) {});
  }
}
