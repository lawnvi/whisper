import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/socket/bounded_binary_websocket_session.dart';

final class _LoopbackSockets {
  _LoopbackSockets(this.server, this.accepted, this.iterator);

  final HttpServer server;
  final StreamController<WebSocket> accepted;
  final StreamIterator<WebSocket> iterator;

  static Future<_LoopbackSockets> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = StreamController<WebSocket>();
    server.listen((request) async {
      accepted.add(await WebSocketTransformer.upgrade(request));
    });
    return _LoopbackSockets(
      server,
      accepted,
      StreamIterator<WebSocket>(accepted.stream),
    );
  }

  Future<({WebSocket client, WebSocket server})> connect() async {
    final client = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}/media',
    );
    expect(await iterator.moveNext(), isTrue);
    return (client: client, server: iterator.current);
  }

  Future<void> close() async {
    await iterator.cancel();
    await accepted.close();
    await server.close(force: true);
  }
}

final class _ReentrantChannel implements WebSocketChannel {
  _ReentrantChannel() {
    late final StreamController<dynamic> controller;
    controller = StreamController<dynamic>(
      sync: true,
      onCancel: () {
        cancelCount += 1;
        _reenterOnce();
      },
    );
    _controller = controller;
    _sink = _ReentrantSink(
      onClose: () {
        sinkCloseCount += 1;
        _reenterOnce();
        return controller.close();
      },
    );
  }

  late final StreamController<dynamic> _controller;
  late final _ReentrantSink _sink;
  void Function()? onReenter;
  int cancelCount = 0;
  int sinkCloseCount = 0;
  bool _reentered = false;

  void addIncoming(Object message) => _controller.add(message);

  void _reenterOnce() {
    if (_reentered) {
      return;
    }
    _reentered = true;
    onReenter?.call();
  }

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReentrantSink implements WebSocketSink {
  _ReentrantSink({required this.onClose});

  final Future<void> Function() onClose;
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  void add(dynamic data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await onClose();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

final class _ControlledChannel implements WebSocketChannel {
  _ControlledChannel({required bool failClose}) {
    _controller = StreamController<dynamic>();
    _sink = _ControlledSink(
      failClose: failClose,
      closeStream: _controller.close,
    );
  }

  late final StreamController<dynamic> _controller;
  late final _ControlledSink _sink;

  Completer<void> get closeStarted => _sink.closeStarted;
  Completer<void> get releaseClose => _sink.releaseClose;
  int get closeCount => _sink.closeCount;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ControlledSink implements WebSocketSink {
  _ControlledSink({
    required this.failClose,
    required this.closeStream,
  });

  final bool failClose;
  final Future<void> Function() closeStream;
  final Completer<void> closeStarted = Completer<void>();
  final Completer<void> releaseClose = Completer<void>();
  final Completer<void> _done = Completer<void>();
  int closeCount = 0;

  @override
  Future<void> get done => _done.future;

  @override
  void add(dynamic data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closeCount += 1;
    if (!closeStarted.isCompleted) {
      closeStarted.complete();
    }
    await releaseClose.future;
    await closeStream();
    if (failClose) {
      throw StateError('controlled close failure');
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

void main() {
  test('a blocked media socket does not block another socket', () async {
    final loopback = await _LoopbackSockets.start();
    addTearDown(loopback.close);
    final firstPair = await loopback.connect();
    final secondPair = await loopback.connect();
    addTearDown(firstPair.client.close);
    addTearDown(secondPair.client.close);
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final secondHandled = Completer<void>();

    final first = BoundedBinaryWebSocketSession(
      channel: IOWebSocketChannel(firstPair.server),
      maxMessageBytes: 256 * 1024,
      onMessage: (_) async {
        firstStarted.complete();
        await releaseFirst.future;
      },
    );
    final second = BoundedBinaryWebSocketSession(
      channel: IOWebSocketChannel(secondPair.server),
      maxMessageBytes: 256 * 1024,
      onMessage: (_) {
        secondHandled.complete();
      },
    );

    firstPair.client.add(Uint8List.fromList(<int>[1]));
    await firstStarted.future;
    secondPair.client.add(Uint8List.fromList(<int>[2]));

    await secondHandled.future.timeout(const Duration(seconds: 2));
    var firstClosed = false;
    final firstClose = first.close().whenComplete(() => firstClosed = true);
    await Future<void>.delayed(Duration.zero);
    expect(firstClosed, isFalse);

    releaseFirst.complete();
    await firstClose;
    await second.close();
  });

  test('oversized or text media messages fail closed', () async {
    for (final invalidMessage in <Object>[
      Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      'not-binary',
    ]) {
      final loopback = await _LoopbackSockets.start();
      final pair = await loopback.connect();
      final received = <Uint8List>[];
      final session = BoundedBinaryWebSocketSession(
        channel: IOWebSocketChannel(pair.server),
        maxMessageBytes: 4,
        onMessage: received.add,
      );
      final clientClosed = pair.client.listen((_) {}).asFuture<void>();

      pair.client.add(invalidMessage);
      await clientClosed.timeout(const Duration(seconds: 2));

      expect(received, isEmpty);
      expect(session.isClosed, isTrue);
      await session.close();
      await pair.client.close();
      await loopback.close();
    }
  });

  test('synchronous close reentrancy closes resources exactly once', () async {
    final channel = _ReentrantChannel();
    var onClosedCount = 0;
    final session = BoundedBinaryWebSocketSession(
      channel: channel,
      maxMessageBytes: 4,
      onMessage: (_) {},
      onClosed: () => onClosedCount += 1,
    );
    channel.onReenter = session.close;

    final first = session.close();
    final second = session.close();

    expect(identical(first, second), isTrue);
    await first;
    expect(channel.cancelCount, 1);
    expect(channel.sinkCloseCount, 1);
    expect(onClosedCount, 1);
  });

  test('an error observer cannot prevent invalid input from closing', () async {
    final channel = _ReentrantChannel();
    final observedError = Completer<Object>();
    late final BoundedBinaryWebSocketSession session;

    runZonedGuarded(
      () {
        session = BoundedBinaryWebSocketSession(
          channel: channel,
          maxMessageBytes: 4,
          onMessage: (_) {},
          onError: (_) => throw StateError('observer failed'),
        );
        channel.addIncoming('not-binary');
      },
      (error, stackTrace) => observedError.complete(error),
    );

    expect(await observedError.future, isA<StateError>());
    await Future<void>.delayed(Duration.zero);
    expect(session.isClosed, isTrue);
    await session.close();
    expect(channel.sinkCloseCount, 1);
  });

  test('manager close awaits concurrent channels after one close fails',
      () async {
    final manager = AudioShareManager();
    final first = _ControlledChannel(failClose: true);
    final second = _ControlledChannel(failClose: false);
    manager.attachChannel(first);

    final closing = manager.closeChannels();
    bool? closingStateOnCompletion;
    final observed = closing.then<Object?>(
      (_) => null,
      onError: (Object error, StackTrace stackTrace) {
        closingStateOnCompletion = manager.isClosingChannels;
        return error;
      },
    );
    var completed = false;
    observed.whenComplete(() => completed = true);
    await first.closeStarted.future;
    manager.attachChannel(second);

    first.releaseClose.complete();
    await second.closeStarted.future;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(completed, isFalse);

    second.releaseClose.complete();
    expect(await observed, isA<StateError>());
    expect(closingStateOnCompletion, isFalse);
    expect(manager.isClosingChannels, isFalse);
    expect(first.closeCount, 1);
    expect(second.closeCount, 1);
    expect(manager.activeChannelCount, 0);
  });
}
