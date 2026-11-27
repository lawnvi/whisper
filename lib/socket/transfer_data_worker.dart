part of 'transfer_data_isolate.dart';

// ---------------------------------------------------------------------------
// Worker isolate entrypoint & runtime
// ---------------------------------------------------------------------------

Future<void> _transferIsolateMain(_IsolateStart start) async {
  try {
    WhisperAead.installNativeAcceleration(await SodiumInit.init());
  } on Object {
    // Pure-Dart AEAD fallback still works in unit tests without native libsodium.
  }
  final receive = ReceivePort();
  final runtime = _TransferWorkerRuntime(start.main, receive);
  try {
    final server = await _TransferDataServer.bind(runtime, start.preferredPort);
    runtime.server = server;
    start.main.send(_WorkerReady(receive.sendPort, server.port));
    receive.listen(runtime.handle);
  } catch (error) {
    receive.close();
    start.main.send(_WorkerStartFailed(error.runtimeType.toString()));
  }
}

final class _TransferWorkerRuntime {
  _TransferWorkerRuntime(this._main, this._receive);

  final SendPort _main;
  final ReceivePort _receive;
  _TransferDataServer? server;

  int _nextChannelId = 0;
  int _nextClaimRequestId = 0;
  bool _shuttingDown = false;

  final Map<int, _TransferWorkerChannel> _channels =
      <int, _TransferWorkerChannel>{};
  final Map<int, Completer<_ClaimData?>> _claimLookups =
      <int, Completer<_ClaimData?>>{};
  final Map<int, Completer<bool>> _claimConsumes = <int, Completer<bool>>{};

  int nextChannelId() => ++_nextChannelId;

  void handle(Object? message) {
    switch (message) {
      case _DialChannel():
        unawaited(_dial(message));
      case _SendFrame():
        final channel = _channels[message.channelId];
        if (channel == null || channel.isClosed) {
          _main.send(_SendAck(message.requestId, false));
          return;
        }
        channel.enqueueSend(message.requestId, message.data);
      case _InboundCredit():
        _channels[message.channelId]?.addInboundCredit(message.bytes);
      case _CloseChannel():
        unawaited(
          _channels[message.channelId]?.close(
                expected: true,
                reason: message.reason,
              ) ??
              Future<void>.value(),
        );
      case _ClosePeerChannels():
        for (final channel in _channels.values.toList(growable: false)) {
          if (channel.peerId != message.peerId) continue;
          if (message.connectionGeneration != null &&
              channel.connectionGeneration != message.connectionGeneration) {
            continue;
          }
          if (message.kind != null && channel.kind != message.kind) continue;
          unawaited(channel.close(expected: true, reason: message.reason));
        }
      case _ClaimAnswer():
        _claimLookups.remove(message.requestId)?.complete(message.claim);
      case _ConsumeAnswer():
        _claimConsumes.remove(message.requestId)?.complete(message.consumed);
      case _ShutdownWorker():
        unawaited(_shutdown());
      default:
        break;
    }
  }

  Future<_ClaimData?> lookupClaim(
    String sessionId,
    String token,
    String remoteAddress,
  ) {
    if (_shuttingDown) {
      return Future<_ClaimData?>.value(null);
    }
    final requestId = ++_nextClaimRequestId;
    final completer = Completer<_ClaimData?>();
    _claimLookups[requestId] = completer;
    _main.send(_LookupClaim(requestId, sessionId, token, remoteAddress));
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _claimLookups.remove(requestId);
        return null;
      },
    );
  }

  Future<bool> consumeClaim(_ClaimData claim) {
    if (_shuttingDown) {
      return Future<bool>.value(false);
    }
    final completer = Completer<bool>();
    _claimConsumes[claim.requestId] = completer;
    _main.send(_ConsumeClaim(claim.requestId));
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _claimConsumes.remove(claim.requestId);
        return false;
      },
    );
  }

  void releaseClaim(_ClaimData claim) {
    claim.zeroKeys();
    _main.send(_ReleaseClaim(claim.requestId));
  }

  Future<void> _dial(_DialChannel command) async {
    try {
      final uri = MediaRoute.transfer.uri(
        host: command.host,
        port: command.port,
        sessionId: command.sessionId,
        token: command.token,
      );
      final channel = await dialMediaChannel(
        uri,
        MediaRoute.transfer,
        sessionId: command.sessionId,
        proverPeerId: command.localPeerId,
        proofKey: command.sendKey,
        connectTimeout: Duration(microseconds: command.connectTimeoutMicros),
        onSocket: command.kind == TransferChannelKind.bulk
            ? tuneTransferBulkSocket
            : tuneTransferBrowseSocket,
      );
      if (_shuttingDown) {
        unawaited(channel.sink.close().catchError((Object _) {}));
        _main.send(_DialResult(command.requestId, ok: false));
        return;
      }
      final binding = mediaPacketChannelBindingFromToken(command.token);
      try {
        final channelId = attachChannel(
          channel: channel,
          peerId: command.remotePeerId,
          connectionGeneration: command.connectionGeneration,
          kind: command.kind,
          sessionId: command.sessionId,
          reverse: command.reverse,
          sendKey: command.sendKey,
          receiveKey: command.receiveKey,
          channelBinding: binding,
        );
        _main.send(
          _DialResult(command.requestId, ok: true, channelId: channelId),
        );
      } finally {
        binding.fillRange(0, binding.length, 0);
      }
    } on Object catch (error) {
      _main.send(
        _DialResult(
          command.requestId,
          ok: false,
          unreachable: mediaPeerUnreachable(error),
        ),
      );
    } finally {
      command.sendKey.fillRange(0, command.sendKey.length, 0);
      command.receiveKey.fillRange(0, command.receiveKey.length, 0);
    }
  }

  int attachChannel({
    required WebSocketChannel channel,
    required String peerId,
    required int connectionGeneration,
    required TransferChannelKind kind,
    required String sessionId,
    required bool reverse,
    required Uint8List sendKey,
    required Uint8List receiveKey,
    required Uint8List channelBinding,
  }) {
    final encoder = AuthenticatedMediaPacketEncoder(
      route: MediaRoute.transfer.path,
      namespace: MediaRoute.transfer.namespace,
      sessionId: sessionId,
      mediaMacKey: sendKey,
      channelBinding: channelBinding,
      maxPayloadBytes: maxTransferFrameBytes,
    );
    final AuthenticatedMediaPacketDecoder decoder;
    try {
      decoder = AuthenticatedMediaPacketDecoder(
        route: MediaRoute.transfer.path,
        namespace: MediaRoute.transfer.namespace,
        sessionId: sessionId,
        mediaMacKey: receiveKey,
        channelBinding: channelBinding,
        maxPayloadBytes: maxTransferFrameBytes,
      );
    } catch (_) {
      encoder.destroy();
      rethrow;
    }
    final channelId = nextChannelId();
    final workerChannel = _TransferWorkerChannel(
      runtime: this,
      channelId: channelId,
      peerId: peerId,
      connectionGeneration: connectionGeneration,
      kind: kind,
      ws: channel,
      encoder: encoder,
      decoder: decoder,
    );
    _channels[channelId] = workerChannel;
    _main.send(
      _ChannelOpened(
        channelId: channelId,
        peerId: peerId,
        connectionGeneration: connectionGeneration,
        kind: kind,
        sessionId: sessionId,
        reverse: reverse,
      ),
    );
    workerChannel.startReading();
    return channelId;
  }

  void _onChannelClosed(
    _TransferWorkerChannel channel, {
    required bool expected,
    required String reason,
  }) {
    if (identical(_channels[channel.channelId], channel)) {
      _channels.remove(channel.channelId);
    }
    if (!_shuttingDown) {
      _main.send(
        _ChannelClosed(
          channelId: channel.channelId,
          peerId: channel.peerId,
          connectionGeneration: channel.connectionGeneration,
          kind: channel.kind,
          expected: expected,
          reason: reason,
        ),
      );
    }
  }

  void _sendAck(int requestId, bool ok) {
    if (!_shuttingDown) {
      _main.send(_SendAck(requestId, ok));
    }
  }

  void _deliverInbound(_TransferWorkerChannel channel, Uint8List clearText) {
    if (_shuttingDown) {
      return;
    }
    _main.send(
      _InboundFrame(
        channelId: channel.channelId,
        peerId: channel.peerId,
        connectionGeneration: channel.connectionGeneration,
        kind: channel.kind,
        data: TransferableTypedData.fromList(<Uint8List>[clearText]),
      ),
    );
  }

  Future<void> _shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    for (final completer in _claimLookups.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _claimLookups.clear();
    for (final completer in _claimConsumes.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _claimConsumes.clear();
    for (final channel in _channels.values.toList(growable: false)) {
      await channel.close(expected: true, reason: 'shutdown');
    }
    await server?.close();
    _receive.close();
  }
}

final class _PendingWorkerSend {
  const _PendingWorkerSend(this.requestId, this.data);

  final int requestId;
  final TransferableTypedData data;
}

final class _TransferWorkerChannel {
  _TransferWorkerChannel({
    required this.runtime,
    required this.channelId,
    required this.peerId,
    required this.connectionGeneration,
    required this.kind,
    required this.ws,
    required this.encoder,
    required this.decoder,
  });

  static const int _inboundHighWaterBytes = 8 * 1024 * 1024;
  static const int _inboundLowWaterBytes = 4 * 1024 * 1024;
  static const Duration _baseWriterTimeout = Duration(seconds: 30);
  static const Duration _maxWriterTimeout = Duration(seconds: 120);
  static const int _minWriteBytesPerSecond = 64 * 1024;

  final _TransferWorkerRuntime runtime;
  final int channelId;
  final String peerId;
  final int connectionGeneration;
  final TransferChannelKind kind;
  final WebSocketChannel ws;
  final AuthenticatedMediaPacketEncoder encoder;
  final AuthenticatedMediaPacketDecoder decoder;

  final Queue<_PendingWorkerSend> _outbound = Queue<_PendingWorkerSend>();
  StreamSubscription<dynamic>? _subscription;
  bool _pumping = false;
  bool _closed = false;
  bool _expectedClose = false;
  int _unackedInboundBytes = 0;
  bool _paused = false;

  bool get isClosed => _closed;

  void startReading() {
    _subscription = ws.stream.listen(
      _onMessage,
      onError: (_) => unawaited(close(expected: false, reason: 'remote_error')),
      onDone: () => unawaited(close(expected: false, reason: 'remote_closed')),
      cancelOnError: false,
    );
  }

  void enqueueSend(int requestId, TransferableTypedData data) {
    if (_closed) {
      runtime._sendAck(requestId, false);
      return;
    }
    _outbound.add(_PendingWorkerSend(requestId, data));
    if (!_pumping) {
      unawaited(_pumpOutbound());
    }
  }

  Future<void> _pumpOutbound() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_outbound.isNotEmpty && !_closed) {
        final item = _outbound.removeFirst();
        try {
          final plaintext = item.data.materialize().asUint8List();
          final sealed = encoder.encode(plaintext);
          await ws.sink
              .addStream(Stream<Object>.value(sealed))
              .timeout(_writerTimeout(sealed.length));
          // Ack strictly AFTER addStream completes so the main-isolate
          // TransferPacer observes real kernel-socket backpressure.
          runtime._sendAck(item.requestId, !_closed);
        } on Object {
          await close(expected: false, reason: 'writer_failure');
          runtime._sendAck(item.requestId, false);
          break;
        }
      }
    } finally {
      _pumping = false;
    }
  }

  void _onMessage(dynamic raw) {
    if (_closed) return;
    if (raw is! List<int> || raw.length > maxTransferChannelMessageBytes) {
      unawaited(close(expected: false, reason: 'protocol_error'));
      return;
    }
    final Uint8List clearText;
    try {
      final encoded = raw is Uint8List ? raw : Uint8List.fromList(raw);
      clearText = decoder.decode(encoded);
      if (!_isAllowedInboundFrame(clearText, kind)) {
        throw const FormatException('disallowed transfer frame');
      }
    } on Object {
      unawaited(close(expected: false, reason: 'protocol_error'));
      return;
    }
    _unackedInboundBytes += clearText.length;
    if (!_paused && _unackedInboundBytes >= _inboundHighWaterBytes) {
      _paused = true;
      _subscription?.pause();
    }
    runtime._deliverInbound(this, clearText);
  }

  void addInboundCredit(int bytes) {
    if (_closed || bytes <= 0) return;
    _unackedInboundBytes = math.max(0, _unackedInboundBytes - bytes);
    if (_paused && _unackedInboundBytes <= _inboundLowWaterBytes) {
      _paused = false;
      _subscription?.resume();
    }
  }

  Future<void> close({required bool expected, required String reason}) async {
    if (_closed) {
      return;
    }
    _closed = true;
    _expectedClose = _expectedClose || expected;
    final sub = _subscription;
    _subscription = null;
    // Notify the main isolate that the channel is closed BEFORE failing
    // pending send acks, so FileTransferEngine can invalidate its active
    // send window before seeing send()==false.
    runtime._onChannelClosed(this, expected: _expectedClose, reason: reason);
    while (_outbound.isNotEmpty) {
      final dropped = _outbound.removeFirst();
      runtime._sendAck(dropped.requestId, false);
    }
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await ws.sink
          .close(expected ? 1000 : 4002, reason)
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    encoder.destroy();
    decoder.destroy();
  }

  static Duration _writerTimeout(int byteLength) {
    final adaptiveMs = (byteLength * 1000) ~/ _minWriteBytesPerSecond;
    final ms = math.max(
      _baseWriterTimeout.inMilliseconds,
      math.min(_maxWriterTimeout.inMilliseconds, adaptiveMs),
    );
    return Duration(milliseconds: ms);
  }

  static bool _isAllowedInboundFrame(
    Uint8List bytes,
    TransferChannelKind kind,
  ) {
    if (bytes.length < WhisperFrameV3.headerLength ||
        !WhisperFrameV3.looksLikeFrame(bytes)) {
      return false;
    }
    final view = ByteData.sublistView(bytes);
    if (view.getUint8(4) != WhisperFrameV3.version ||
        view.getUint32(8) != WhisperFrameV3.headerLength) {
      return false;
    }
    final payloadLength = view.getUint32(12);
    if (payloadLength > fileTransferV3FramePayloadSize ||
        bytes.length != WhisperFrameV3.headerLength + payloadLength) {
      return false;
    }
    final typeCode = view.getUint8(5);
    return switch (kind) {
      TransferChannelKind.bulk => typeCode == WhisperFrameType.fileData.code,
      TransferChannelKind.browse =>
        typeCode == WhisperFrameType.browseData.code ||
            typeCode == WhisperFrameType.browseWrite.code,
    };
  }
}
