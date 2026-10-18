import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'agent_link.dart';
import 'agent_wire.dart';

/// An error the agent returned for a request.
class AgentCallException implements Exception {
  const AgentCallException(this.method, this.message);

  final String method;
  final String message;

  @override
  String toString() => 'AgentCallException($method: $message)';
}

/// An event the agent pushed (`launched`, `closed`…).
class AgentEvent {
  const AgentEvent(this.name, this.data);

  final String name;
  final Map<String, dynamic> data;
}

/// The client end of whisper-agent's control connection (a desktop through
/// an adb forward, or the phone's own Whisper through the app link): JSON
/// requests with ids, answered out of order, plus pushed events.
class AgentControlClient {
  AgentControlClient._(this._socket, Stream<Uint8List> input) {
    _subscription = input.listen(
      _onData,
      onError: (Object error) => _fail(error),
      onDone: () => _fail(const SocketException('agent closed the connection')),
      cancelOnError: true,
    );
  }

  /// Through an adb forward: the hello carries the token (adb is shell).
  static Future<AgentControlClient> connect({
    required int port,
    required Uint8List token,
    String host = '127.0.0.1',
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.add(AgentWire.hello(AgentWire.roleControl, 0, token));
    return AgentControlClient._(socket, socket);
  }

  /// Through the phone's app link (challenge, no token on the wire).
  static Future<AgentControlClient> connectLink(
    AgentLinkInfo link, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final connection = await AgentLink.connect(
      link,
      role: AgentWire.roleControl,
      timeout: timeout,
    );
    return AgentControlClient._(connection.socket, connection.input);
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final _reader = AgentMessageReader();
  final _pending = <int, (String, Completer<Object?>)>{};
  final _events = StreamController<AgentEvent>.broadcast();
  final _closed = Completer<void>();
  int _nextId = 1;
  bool _isClosed = false;

  Stream<AgentEvent> get events => _events.stream;

  /// Completes when the connection is gone, for whatever reason.
  Future<void> get done => _closed.future;
  bool get isClosed => _isClosed;

  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 15),
  ]) {
    if (_isClosed) {
      return Future.error(AgentCallException(method, 'disconnected'));
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = (method, completer);
    _socket.add(
      AgentWire.frame({'id': id, 'method': method, 'params': params}),
    );
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw AgentCallException(method, 'timeout');
      },
    );
  }

  void _onData(Uint8List chunk) {
    final List<Object?> messages;
    try {
      messages = _reader.add(chunk);
    } on FormatException catch (error) {
      _fail(error);
      return;
    }
    for (final message in messages) {
      if (message is! Map) {
        continue;
      }
      final event = message['event'];
      if (event is String) {
        final data = message['data'];
        _events.add(
          AgentEvent(
            event,
            data is Map ? data.cast<String, dynamic>() : const {},
          ),
        );
        continue;
      }
      final id = message['id'];
      if (id is! int) {
        continue;
      }
      final pending = _pending.remove(id);
      if (pending == null) {
        continue;
      }
      final error = message['error'];
      if (error != null) {
        pending.$2.completeError(AgentCallException(pending.$1, '$error'));
      } else {
        pending.$2.complete(message['result']);
      }
    }
  }

  void _fail(Object error) {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    for (final pending in _pending.values) {
      pending.$2.completeError(AgentCallException(pending.$1, '$error'));
    }
    _pending.clear();
    _socket.destroy();
    unawaited(_events.close());
    _closed.complete();
  }

  Future<void> close() async {
    await _subscription.cancel();
    _fail(const SocketException('closed'));
  }
}
