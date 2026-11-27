import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// The relay between the Whisper server (UI isolate), which accepted and
/// authenticated the host's `/window` socket, and the stream isolate,
/// which decrypts its packets.
///
/// Ports carry packets as [TransferableTypedData] (or [Uint8List]) and these
/// control messages:
/// - worker → UI: its own [SendPort] first, positive `int` credit refills as
///   packets are delivered to the worker's stream consumer, packets to write,
///   then [close];
/// - UI → worker: [connected] once the host's socket is in, up to
///   [initialCredits] packets without refill (pausing the socket subscription
///   when credits reach zero), then [closed].
abstract final class InboundWindowRelay {
  static const String connected = 'connected';
  static const String closed = 'closed';
  static const String close = 'close';

  /// Packets allowed in flight from the UI socket to the worker isolate
  /// before pausing socket reads.
  static const int initialCredits = 64;

  /// Consumed packets batched before returning credit to the UI isolate.
  static const int refillThreshold = 16;
}

/// The UI isolate's end of [InboundWindowRelay] for one stream: relays the
/// authenticated `/window` socket to the stream isolate with credit-based
/// backpressure so a slow decoder pauses socket reads instead of buffering
/// unbounded frames across the isolate port.
class InboundWindowHostRelay {
  InboundWindowHostRelay({
    required this.hostPeerId,
    required this.binding,
    this.initialCredits = InboundWindowRelay.initialCredits,
  }) : _credits = initialCredits {
    _fromWorker.listen(_onWorker);
  }

  final String hostPeerId;

  /// The token this viewer issued, as the packets' channel binding.
  final Uint8List binding;
  final int initialCredits;
  final _fromWorker = ReceivePort('window-inbound-relay');
  SendPort? _toWorker;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _reading;
  int _credits;
  bool _paused = false;
  bool _closed = false;

  SendPort get port => _fromWorker.sendPort;

  bool get awaiting => !_closed && _channel == null;

  bool get isPaused => _paused;

  bool attach(WebSocketChannel channel) {
    if (!awaiting) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    _channel = channel;
    _relay();
    return true;
  }

  void _onWorker(Object? message) {
    if (message is SendPort) {
      _toWorker = message;
      _relay();
    } else if (message is int && message > 0) {
      _credits += message;
      if (_paused && _credits > 0) {
        _paused = false;
        _reading?.resume();
      }
    } else if (message is Uint8List) {
      _channel?.sink.add(message);
    } else if (message == InboundWindowRelay.close) {
      close();
    }
  }

  void _relay() {
    final toWorker = _toWorker;
    final channel = _channel;
    if (toWorker == null || channel == null || _reading != null || _closed) {
      return;
    }
    toWorker.send(InboundWindowRelay.connected);
    _reading = channel.stream.listen(
      (message) {
        final Uint8List bytes;
        if (message is Uint8List) {
          bytes = message;
        } else if (message is List<int>) {
          bytes = Uint8List.fromList(message);
        } else {
          return;
        }
        toWorker.send(TransferableTypedData.fromList(<TypedData>[bytes]));
        _credits -= 1;
        if (_credits <= 0 && !_paused) {
          _paused = true;
          _reading?.pause();
        }
      },
      onError: (Object _) {},
      onDone: close,
    );
    if (_credits <= 0) {
      _paused = true;
      _reading?.pause();
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _toWorker?.send(InboundWindowRelay.closed);
    unawaited(_reading?.cancel());
    unawaited(_channel?.sink.close().catchError((Object _) {}));
    _fromWorker.close();
    binding.fillRange(0, binding.length, 0);
  }
}

/// The worker's side of [InboundWindowRelay], shaped as a WebSocket channel
/// so the stream runs exactly as over a socket it dialled itself.
///
/// Credits are returned to the UI isolate only as packets are delivered to an
/// active, unpaused stream listener, propagating [BoundedBinaryWebSocketSession]
/// pause/resume back to the TCP socket on the UI isolate.
class InboundWindowRelayChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  InboundWindowRelayChannel(
    this._toMain, {
    this.refillThreshold = InboundWindowRelay.refillThreshold,
  }) : _sink = _RelaySink(_toMain) {
    _incoming = StreamController<dynamic>(
      onListen: _drain,
      onResume: _drain,
      onCancel: () {
        _pending.clear();
        _sink.close();
      },
    );
    _receive.listen((message) {
      if (message is TransferableTypedData) {
        _enqueue(message.materialize().asUint8List());
      } else if (message is Uint8List) {
        _enqueue(message);
      } else if (message == InboundWindowRelay.connected) {
        if (!_connected.isCompleted) {
          _connected.complete();
        }
      } else if (message == InboundWindowRelay.closed) {
        _remoteClosed = true;
        if (_pending.isEmpty) {
          shutdown();
        } else {
          _drain();
        }
      }
    });
    _toMain.send(_receive.sendPort);
  }

  final SendPort _toMain;
  final int refillThreshold;
  final _receive = ReceivePort('window-inbound');
  late final StreamController<dynamic> _incoming;
  final _pending = Queue<Uint8List>();
  final _connected = Completer<void>();
  final _RelaySink _sink;
  int _unreturnedCredits = 0;
  bool _remoteClosed = false;
  bool _closed = false;

  Future<void> get connected => _connected.future;

  void _enqueue(Uint8List bytes) {
    if (_closed) {
      return;
    }
    if (_incoming.hasListener && !_incoming.isPaused && _pending.isEmpty) {
      _deliver(bytes);
      return;
    }
    _pending.add(bytes);
  }

  void _drain() {
    while (!_closed &&
        _incoming.hasListener &&
        !_incoming.isPaused &&
        _pending.isNotEmpty) {
      _deliver(_pending.removeFirst());
    }
    if (_remoteClosed && _pending.isEmpty) {
      shutdown();
    }
  }

  void _deliver(Uint8List bytes) {
    _incoming.add(bytes);
    _unreturnedCredits += 1;
    if (_unreturnedCredits >= refillThreshold) {
      final refill = _unreturnedCredits;
      _unreturnedCredits = 0;
      _toMain.send(refill);
    }
  }

  void shutdown() {
    if (_closed) {
      return;
    }
    _closed = true;
    _pending.clear();
    if (!_connected.isCompleted) {
      _connected.completeError(const SocketException('relay closed'));
    }
    _receive.close();
    unawaited(_incoming.close());
    _sink._finish();
  }

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => _connected.future;
}

class _RelaySink implements WebSocketSink {
  _RelaySink(this._toMain);

  final SendPort _toMain;
  final _done = Completer<void>();

  void _finish() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  void add(dynamic data) {
    if (_done.isCompleted) {
      return;
    }
    _toMain.send(
      data is Uint8List ? data : Uint8List.fromList(data as List<int>),
    );
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    if (!_done.isCompleted) {
      _toMain.send(InboundWindowRelay.close);
      _finish();
    }
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;
}
