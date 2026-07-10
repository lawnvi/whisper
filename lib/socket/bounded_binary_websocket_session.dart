import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/bounded_receive_queue.dart';

typedef BinaryWebSocketMessageHandler = FutureOr<void> Function(
  Uint8List bytes,
);

final class BoundedBinaryWebSocketSession {
  BoundedBinaryWebSocketSession({
    required WebSocketChannel channel,
    required this.maxMessageBytes,
    required BinaryWebSocketMessageHandler onMessage,
    void Function(Object error)? onError,
    void Function()? onClosed,
  })  : _channel = channel,
        _onMessage = onMessage,
        _onError = onError,
        _onClosed = onClosed {
    if (maxMessageBytes <= 0) {
      throw ArgumentError.value(maxMessageBytes, 'maxMessageBytes');
    }
    _queue = BoundedReceiveQueue(
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onOverflow: () => _failClosed(
        StateError('binary websocket receive queue overflow'),
      ),
    );
    final subscription = channel.stream.listen(
      _handleMessage,
      onError: (Object error, StackTrace stackTrace) => _failClosed(error),
      onDone: _handleDone,
      cancelOnError: false,
    );
    _subscription = subscription;
    if (_closing) {
      unawaited(
        subscription.cancel().catchError((Object _, StackTrace __) {}),
      );
    }
  }

  final WebSocketChannel _channel;
  final int maxMessageBytes;
  final BinaryWebSocketMessageHandler _onMessage;
  final void Function(Object error)? _onError;
  final void Function()? _onClosed;
  late final BoundedReceiveQueue _queue;
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _closeFuture;
  bool _closing = false;

  bool get isClosed => _closing;
  int get pendingItems => _queue.pendingItems;
  int get pendingBytes => _queue.pendingBytes;
  bool get isPaused => _queue.isPaused;

  void _handleMessage(dynamic message) {
    if (_closing) {
      return;
    }
    if (message is! List<int>) {
      _failClosed(const FormatException('binary websocket message required'));
      return;
    }
    if (message.length > maxMessageBytes) {
      _failClosed(
        FormatException(
          'binary websocket message exceeds $maxMessageBytes bytes',
        ),
      );
      return;
    }
    final bytes = Uint8List.fromList(message);
    final queued = _queue.add(bytes.length, () async {
      await _onMessage(bytes);
    });
    unawaited(queued.then<void>((accepted) {
      if (!accepted) {
        _failClosed(StateError('binary websocket receive queue closed'));
      }
    }).catchError((Object error, StackTrace stackTrace) {
      _failClosed(error);
    }));
  }

  void _failClosed(Object error) {
    if (_closing) {
      return;
    }
    try {
      _onError?.call(error);
    } finally {
      unawaited(
        _beginClose().catchError((Object _, StackTrace __) {}),
      );
    }
  }

  void _handleDone() {
    unawaited(
      _beginClose(
        cancelSubscription: false,
      ).catchError((Object _, StackTrace __) {}),
    );
  }

  Future<void> close() => _beginClose();

  Future<void> _beginClose({bool cancelSubscription = true}) {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closing = true;
    final completer = Completer<void>();
    final closeFuture = completer.future;
    _closeFuture = closeFuture;
    final subscription = _subscription;
    unawaited(() async {
      try {
        await Future.wait(<Future<void>>[
          if (cancelSubscription && subscription != null) subscription.cancel(),
          _queue.closeAndDrain(),
          _channel.sink.close(),
        ]);
      } finally {
        if (identical(_subscription, subscription)) {
          _subscription = null;
        }
        _onClosed?.call();
      }
    }()
        .then<void>(
      (_) => completer.complete(),
      onError: (Object error, StackTrace stackTrace) =>
          completer.completeError(error, stackTrace),
    ));
    return closeFuture;
  }
}
