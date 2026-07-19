import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/bounded_binary_websocket_session.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

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

  Future<void> closeRemote() => _controller.close();

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
  _ControlledSink({required this.failClose, required this.closeStream});

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
  test(
    'remote input callback completion drives websocket receive watermarks',
    () async {
      final manager = RemoteInputManager();
      const sessionId = '11111111-1111-4111-8111-111111111111';
      manager.acceptOffer(
        const RemoteInputControlMessage(
          action: RemoteInputControlAction.offer,
          sessionId: sessionId,
          sourcePeerId: 'peer-a',
          sinkPeerId: 'local',
          layoutEdge: RemoteInputEdge.right,
        ),
      );
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final delivered = <int>[];
      manager.onPacket = (packet) async {
        delivered.add(packet.sequence);
        if (packet.sequence == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        }
      };
      final channel = _ReentrantChannel();
      final session = BoundedBinaryWebSocketSession(
        channel: channel,
        maxMessageBytes: RemoteInputManager.maxChannelMessageBytes,
        onMessage: manager.handlePacketBytes,
      );
      Uint8List packet(int sequence) => RemoteInputPacketFrame(
        sessionId: sessionId,
        sequence: sequence,
        timestampMicros: sequence,
        eventType: RemoteInputEventType.release,
        payload: Uint8List(0),
      ).encode();

      channel.addIncoming(packet(1));
      await firstStarted.future;
      channel.addIncoming(packet(2));
      await Future<void>.delayed(Duration.zero);

      expect(delivered, <int>[1]);
      expect(session.pendingItems, 2);

      releaseFirst.complete();
      for (var i = 0; i < 10 && delivered.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(delivered, <int>[1, 2]);
      await session.close();
    },
  );

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

    runZonedGuarded(() {
      session = BoundedBinaryWebSocketSession(
        channel: channel,
        maxMessageBytes: 4,
        onMessage: (_) {},
        onError: (_) => throw StateError('observer failed'),
      );
      channel.addIncoming('not-binary');
    }, (error, stackTrace) => observedError.complete(error));

    expect(await observedError.future, isA<StateError>());
    await Future<void>.delayed(Duration.zero);
    expect(session.isClosed, isTrue);
    await session.close();
    expect(channel.sinkCloseCount, 1);
  });

  test(
    'manager close awaits concurrent channels after one close fails',
    () async {
      final manager = AudioShareManager();
      const sessionId = '11111111-1111-4111-8111-111111111111';
      manager.acceptOffer(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: sessionId,
          sourcePeerId: 'peer-a',
          sinkPeerId: 'local',
          format: AudioStreamFormat(
            codec: AudioCodecKind.opus,
            sampleRate: 48000,
            channels: 2,
            frameDurationMs: 20,
            bitRate: 128000,
          ),
        ),
      );
      final claim = SessionUpgradeClaim(
        route: '/audio',
        namespace: 'audio',
        sessionId: sessionId,
        peerId: 'peer-a',
        mediaMacKey: Uint8List(32),
        channelBinding: Uint8List(32),
      );
      final first = _ControlledChannel(failClose: true);
      final second = _ControlledChannel(failClose: false);
      manager.attachChannel(first, claim: claim);

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
      manager.attachChannel(second, claim: claim);

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
    },
  );

  test('audio manager reports an unexpected remote channel close', () async {
    final manager = AudioShareManager();
    const sessionId = '11111111-1111-4111-8111-111111111111';
    manager.acceptOffer(
      const AudioControlMessage(
        action: AudioControlAction.offer,
        sessionId: sessionId,
        sourcePeerId: 'peer-a',
        sinkPeerId: 'local',
        format: AudioStreamFormat(
          codec: AudioCodecKind.opus,
          sampleRate: 48000,
          channels: 2,
          frameDurationMs: 20,
          bitRate: 128000,
        ),
      ),
    );
    final channel = _ControlledChannel(failClose: false);
    final event = Completer<AudioMediaChannelClosedEvent>();
    manager.addChannelLifecycleListener(event.complete);
    manager.attachChannel(
      channel,
      claim: SessionUpgradeClaim(
        route: '/audio',
        namespace: 'audio',
        sessionId: sessionId,
        peerId: 'peer-a',
        mediaMacKey: Uint8List(32),
        channelBinding: Uint8List(32),
      ),
    );

    await channel.closeRemote();
    await channel.closeStarted.future;
    channel.releaseClose.complete();

    final observed = await event.future;
    expect(observed.claim.sessionId, sessionId);
    expect(observed.expected, isFalse);
    expect(manager.activeChannelCount, 0);
  });

  test('audio manager distinguishes session stop from peer loss', () async {
    const sessionId = '11111111-1111-4111-8111-111111111111';

    Future<AudioMediaChannelClosedEvent> close({
      required bool stopSession,
    }) async {
      final manager = AudioShareManager();
      manager.acceptOffer(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: sessionId,
          sourcePeerId: 'peer-a',
          sinkPeerId: 'local',
          format: AudioStreamFormat(
            codec: AudioCodecKind.opus,
            sampleRate: 48000,
            channels: 2,
            frameDurationMs: 20,
            bitRate: 128000,
          ),
        ),
      );
      final channel = _ControlledChannel(failClose: false);
      final event = Completer<AudioMediaChannelClosedEvent>();
      manager.addChannelLifecycleListener(event.complete);
      manager.attachChannel(
        channel,
        claim: SessionUpgradeClaim(
          route: '/audio',
          namespace: 'audio',
          sessionId: sessionId,
          peerId: 'peer-a',
          mediaMacKey: Uint8List(32),
          channelBinding: Uint8List(32),
        ),
      );

      final closing = stopSession
          ? manager.closeSessionChannels(
              sessionId,
              peerId: 'peer-a',
              namespace: 'audio',
            )
          : manager.closePeerChannels('peer-a');
      await channel.closeStarted.future;
      channel.releaseClose.complete();
      await closing;
      return event.future;
    }

    expect((await close(stopSession: true)).expected, isTrue);
    expect((await close(stopSession: false)).expected, isFalse);
  });

  test(
    'attach revalidates the authenticated peer after token consumption',
    () async {
      final manager = AudioShareManager();
      const sessionId = '11111111-1111-4111-8111-111111111111';
      manager.acceptOffer(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: sessionId,
          sourcePeerId: 'peer-a',
          sinkPeerId: 'local',
          format: AudioStreamFormat(
            codec: AudioCodecKind.opus,
            sampleRate: 48000,
            channels: 2,
            frameDurationMs: 20,
            bitRate: 128000,
          ),
        ),
      );
      final channel = _ControlledChannel(failClose: false);

      final attached = manager.attachChannel(
        channel,
        claim: SessionUpgradeClaim(
          route: '/audio',
          namespace: 'audio',
          sessionId: sessionId,
          peerId: 'peer-a',
          mediaMacKey: Uint8List(32),
          channelBinding: Uint8List(32),
        ),
        claimValidator: (_) => false,
      );

      expect(attached, isFalse);
      await channel.closeStarted.future;
      channel.releaseClose.complete();
      await Future<void>.delayed(Duration.zero);
      expect(channel.closeCount, 1);
      expect(manager.activeChannelCount, 0);
    },
  );

  test(
    'terminal cleanup isolates direct and group audio sharing one tuple',
    () async {
      final manager = AudioShareManager();
      const sessionId = '11111111-1111-4111-8111-111111111111';
      manager.acceptOffer(
        const AudioControlMessage(
          action: AudioControlAction.offer,
          sessionId: sessionId,
          sourcePeerId: 'peer-a',
          sinkPeerId: 'local',
          format: AudioStreamFormat(
            codec: AudioCodecKind.opus,
            sampleRate: 48000,
            channels: 2,
            frameDurationMs: 20,
            bitRate: 128000,
          ),
        ),
      );
      final direct = _ControlledChannel(failClose: false);
      final group = _ControlledChannel(failClose: false);
      manager.attachChannel(
        direct,
        claim: SessionUpgradeClaim(
          route: '/audio',
          namespace: 'audio',
          sessionId: sessionId,
          peerId: 'peer-a',
          mediaMacKey: Uint8List(32),
          channelBinding: Uint8List(32),
        ),
      );
      manager.attachChannel(
        group,
        claim: SessionUpgradeClaim(
          route: '/audio',
          namespace: 'audio-group',
          sessionId: sessionId,
          peerId: 'peer-a',
          mediaMacKey: Uint8List(32),
          channelBinding: Uint8List(32),
        ),
        additionalValidator: (_) => true,
        groupPacketValidator: (_, __) => true,
      );
      expect(manager.activeChannelCount, 2);

      final closingDirect = manager.closeSessionChannels(
        sessionId,
        peerId: 'peer-a',
        namespace: 'audio',
      );
      await direct.closeStarted.future;
      direct.releaseClose.complete();
      await closingDirect;

      expect(group.closeStarted.isCompleted, isFalse);
      expect(manager.activeChannelCount, 1);
      final closingGroup = manager.closeChannels();
      await group.closeStarted.future;
      group.releaseClose.complete();
      await closingGroup;
    },
  );

  test(
    'new audio generation closes old-key channels but preserves its own',
    () async {
      final manager = AudioShareManager();
      const oldSessionId = '11111111-1111-4111-8111-111111111111';
      const newSessionId = '22222222-2222-4222-8222-222222222222';
      for (final sessionId in <String>[oldSessionId, newSessionId]) {
        manager.acceptOffer(
          AudioControlMessage(
            action: AudioControlAction.offer,
            sessionId: sessionId,
            sourcePeerId: 'peer-a',
            sinkPeerId: 'local',
            format: const AudioStreamFormat(
              codec: AudioCodecKind.opus,
              sampleRate: 48000,
              channels: 2,
              frameDurationMs: 20,
              bitRate: 128000,
            ),
          ),
        );
      }
      final oldKey = Uint8List.fromList(List<int>.filled(32, 1));
      final newKey = Uint8List.fromList(List<int>.filled(32, 2));
      final oldChannel = _ControlledChannel(failClose: false);
      final newChannel = _ControlledChannel(failClose: false);
      manager.attachChannel(
        oldChannel,
        claim: SessionUpgradeClaim(
          route: '/audio',
          namespace: 'audio',
          sessionId: oldSessionId,
          peerId: 'peer-a',
          mediaMacKey: oldKey,
          channelBinding: Uint8List(32),
        ),
      );
      manager.attachChannel(
        newChannel,
        claim: SessionUpgradeClaim(
          route: '/audio',
          namespace: 'audio',
          sessionId: newSessionId,
          peerId: 'peer-a',
          mediaMacKey: newKey,
          channelBinding: Uint8List(32),
        ),
      );

      final closingOld = manager.closeSupersededPeerChannels(
        'peer-a',
        mediaMacKey: newKey,
      );
      await oldChannel.closeStarted.future;
      oldChannel.releaseClose.complete();
      await closingOld;

      expect(newChannel.closeStarted.isCompleted, isFalse);
      expect(manager.activeChannelCount, 1);
      final closingNew = manager.closeChannels();
      await newChannel.closeStarted.future;
      newChannel.releaseClose.complete();
      await closingNew;
    },
  );

  test(
    'new input generation closes old-key channels but preserves its own',
    () async {
      final manager = RemoteInputManager();
      const oldSessionId = '11111111-1111-4111-8111-111111111111';
      const newSessionId = '22222222-2222-4222-8222-222222222222';
      for (final sessionId in <String>[oldSessionId, newSessionId]) {
        manager.acceptOffer(
          RemoteInputControlMessage(
            action: RemoteInputControlAction.offer,
            sessionId: sessionId,
            sourcePeerId: 'peer-a',
            sinkPeerId: 'local',
            layoutEdge: RemoteInputEdge.right,
          ),
        );
      }
      final oldKey = Uint8List.fromList(List<int>.filled(32, 1));
      final newKey = Uint8List.fromList(List<int>.filled(32, 2));
      final oldChannel = _ControlledChannel(failClose: false);
      final newChannel = _ControlledChannel(failClose: false);
      manager.attachChannel(
        oldChannel,
        claim: SessionUpgradeClaim(
          route: '/input',
          namespace: 'remote-input',
          sessionId: oldSessionId,
          peerId: 'peer-a',
          mediaMacKey: oldKey,
          channelBinding: Uint8List(32),
        ),
      );
      manager.attachChannel(
        newChannel,
        claim: SessionUpgradeClaim(
          route: '/input',
          namespace: 'remote-input',
          sessionId: newSessionId,
          peerId: 'peer-a',
          mediaMacKey: newKey,
          channelBinding: Uint8List(32),
        ),
      );

      final closingOld = manager.closeSupersededPeerChannels(
        'peer-a',
        mediaMacKey: newKey,
      );
      await oldChannel.closeStarted.future;
      oldChannel.releaseClose.complete();
      await closingOld;

      expect(newChannel.closeStarted.isCompleted, isFalse);
      expect(manager.activeChannelCount, 1);
      final closingNew = manager.closeChannels();
      await newChannel.closeStarted.future;
      newChannel.releaseClose.complete();
      await closingNew;
    },
  );
}
