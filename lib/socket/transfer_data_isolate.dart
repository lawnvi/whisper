import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sodium/sodium.dart' show SodiumInit;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/aead_engine.dart';
import 'package:whisper/socket/backpressure_web_socket.dart';
import 'package:whisper/socket/file_transfer_v3.dart'
    show fileTransferV3FramePayloadSize;
import 'package:whisper/socket/media_channel_dial.dart';
import 'package:whisper/socket/media_dial_back.dart' show mediaPeerUnreachable;
import 'package:whisper/socket/media_upgrade_server.dart';
import 'package:whisper/socket/no_delay_socket.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/transfer_channel_protocol.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/whisper_ports.dart';

part 'transfer_data_server.dart';
part 'transfer_data_worker.dart';

/// Maximum plaintext `WhisperFrameV3` bytes allowed on `/transfer`.
const int maxTransferFrameBytes =
    WhisperFrameV3.headerLength + fileTransferV3FramePayloadSize;

/// Maximum encrypted `WEP1` message bytes on `/transfer`.
const int maxTransferChannelMessageBytes =
    maxTransferFrameBytes + AuthenticatedMediaPacketEnvelope.overheadBytes;

/// Connect/upgrade timeout for `/transfer` forward and dial-back connections.
/// Only bounds reaching the peer and upgrading the WebSocket, never the proof.
const Duration transferChannelConnectTimeout = Duration(seconds: 2);

/// Lookup result returned by [TransferClaimBroker.lookup] on the main isolate.
final class TransferClaimLookupResult {
  const TransferClaimLookupResult({
    required this.claim,
    required this.kind,
    required this.sendKey,
  });

  final SessionUpgradeClaim claim;
  final TransferChannelKind kind;

  /// Local `mediaSendKey` for the same `(peerId, connectionGeneration)` so the
  /// worker can encrypt outbound frames on this bidirectional channel.
  final Uint8List sendKey;

  void destroy() {
    claim.destroy();
    sendKey.fillRange(0, sendKey.length, 0);
  }
}

/// Main-isolate token broker consulted by [TransferDataIsolate]'s own server.
abstract interface class TransferClaimBroker {
  TransferClaimLookupResult? lookup({
    required String sessionId,
    required String token,
    required Object remoteAddress,
  });

  bool consume({
    required String sessionId,
    required String token,
    required SessionUpgradeClaim expected,
  });
}

/// Event delivered to the main isolate when a `/transfer` channel opens.
final class TransferDataChannelOpened {
  const TransferDataChannelOpened({
    required this.channelId,
    required this.peerId,
    required this.connectionGeneration,
    required this.kind,
    required this.sessionId,
    required this.reverse,
  });

  final int channelId;
  final String peerId;
  final int connectionGeneration;
  final TransferChannelKind kind;
  final String sessionId;
  final bool reverse;
}

/// Event delivered to the main isolate when a `/transfer` channel closes.
final class TransferDataChannelClosed {
  const TransferDataChannelClosed({
    required this.channelId,
    required this.peerId,
    required this.connectionGeneration,
    required this.kind,
    required this.expected,
    required this.reason,
  });

  final int channelId;
  final String peerId;
  final int connectionGeneration;
  final TransferChannelKind kind;
  final bool expected;
  final String reason;
}

/// Decrypted and frame-type-validated inbound frame from `/transfer`.
final class TransferDataInboundFrame {
  const TransferDataInboundFrame({
    required this.channelId,
    required this.peerId,
    required this.connectionGeneration,
    required this.kind,
    required this.bytes,
  });

  final int channelId;
  final String peerId;
  final int connectionGeneration;
  final TransferChannelKind kind;
  final Uint8List bytes;
}

/// Result of asking the worker isolate to dial a peer's `/transfer` port.
final class TransferDataDialResult {
  const TransferDataDialResult({
    required this.ok,
    this.channelId,
    this.unreachable = false,
  });

  final bool ok;
  final int? channelId;
  final bool unreachable;
}

/// Dedicated worker isolate owning all `/transfer` TCP/WebSocket sockets,
/// XChaCha20-Poly1305 encryption/decryption, and bidirectional backpressure.
///
/// Main isolate owns control state, `TransferPacer`, DB, and file/mount
/// coordinators, exchanging frame bytes zero-copy via [TransferableTypedData].
final class TransferDataIsolate {
  TransferDataIsolate({
    required this.claimBroker,
    required this.onChannelOpened,
    required this.onChannelClosed,
    required this.onInboundFrame,
  });

  final TransferClaimBroker claimBroker;
  final void Function(TransferDataChannelOpened event) onChannelOpened;
  final void Function(TransferDataChannelClosed event) onChannelClosed;
  final FutureOr<void> Function(TransferDataInboundFrame frame) onInboundFrame;

  Isolate? _isolate;
  ReceivePort? _receive;
  SendPort? _worker;
  int _port = 0;
  bool _closed = false;
  int _nextRequestId = 0;
  Future<int>? _starting;

  final Map<int, Completer<TransferDataDialResult>> _pendingDials =
      <int, Completer<TransferDataDialResult>>{};
  final Map<int, Completer<bool>> _pendingSends = <int, Completer<bool>>{};
  final Map<int, _PendingClaim> _pendingClaims = <int, _PendingClaim>{};

  /// Port the worker isolate's `/transfer` server is listening on (0 until
  /// [start] completes).
  int get port => _port;

  bool get isRunning => _worker != null && !_closed && _port > 0;

  /// Spawns the worker isolate and binds its `/transfer` HTTP server on
  /// [preferredPort] (or the next free port in [WhisperPorts.candidates],
  /// falling back to an ephemeral port). Idempotent while running.
  Future<int> start({required int preferredPort}) {
    if (_closed) {
      return Future<int>.value(0);
    }
    if (isRunning) {
      return Future<int>.value(_port);
    }
    return _starting ??= _startInternal(preferredPort);
  }

  Future<int> _startInternal(int preferredPort) async {
    final receive = ReceivePort();
    _receive = receive;
    final ready = Completer<({SendPort port, int listenPort})>();
    receive.listen((Object? message) {
      if (message is _WorkerReady) {
        if (!ready.isCompleted) {
          ready.complete((port: message.sendPort, listenPort: message.port));
        }
        return;
      }
      if (message is _WorkerStartFailed) {
        if (!ready.isCompleted) {
          ready.completeError(StateError(message.reason));
        }
        return;
      }
      _handleWorkerMessage(message);
    });
    try {
      _isolate = await Isolate.spawn(
        _transferIsolateMain,
        _IsolateStart(receive.sendPort, preferredPort),
        debugName: 'whisper-transfer-data',
      );
      final started = await ready.future.timeout(const Duration(seconds: 10));
      if (_closed) {
        started.port.send(const _ShutdownWorker());
        return 0;
      }
      _worker = started.port;
      _port = started.listenPort;
      return _port;
    } catch (_) {
      await close();
      return 0;
    } finally {
      _starting = null;
    }
  }

  /// Dials a peer's `/transfer` port from inside the worker isolate, proves
  /// [token], attaches bidirectional encryption using [sendKey] / [receiveKey],
  /// and returns the new `channelId` on success.
  Future<TransferDataDialResult> dial({
    required String host,
    required int port,
    required String sessionId,
    required String token,
    required String localPeerId,
    required String remotePeerId,
    required int connectionGeneration,
    required TransferChannelKind kind,
    required bool reverse,
    required Uint8List sendKey,
    required Uint8List receiveKey,
    Duration connectTimeout = transferChannelConnectTimeout,
  }) {
    final worker = _worker;
    if (worker == null || _closed) {
      return Future<TransferDataDialResult>.value(
        const TransferDataDialResult(ok: false),
      );
    }
    final requestId = ++_nextRequestId;
    final completer = Completer<TransferDataDialResult>();
    _pendingDials[requestId] = completer;
    worker.send(
      _DialChannel(
        requestId: requestId,
        host: host,
        port: port,
        sessionId: sessionId,
        token: token,
        localPeerId: localPeerId,
        remotePeerId: remotePeerId,
        connectionGeneration: connectionGeneration,
        kind: kind,
        reverse: reverse,
        sendKey: Uint8List.fromList(sendKey),
        receiveKey: Uint8List.fromList(receiveKey),
        connectTimeoutMicros: connectTimeout.inMicroseconds,
      ),
    );
    return completer.future;
  }

  /// Sends one complete `WhisperFrameV3` payload over [channelId] zero-copy
  /// via [TransferableTypedData]. Resolves ONLY AFTER the worker's
  /// `WebSocket.addStream` completes (real kernel socket backpressure).
  Future<bool> sendFrame({
    required int channelId,
    required Uint8List encodedFrame,
  }) {
    final worker = _worker;
    if (worker == null || _closed) {
      return Future<bool>.value(false);
    }
    final requestId = ++_nextRequestId;
    final completer = Completer<bool>();
    _pendingSends[requestId] = completer;
    worker.send(
      _SendFrame(
        requestId: requestId,
        channelId: channelId,
        data: TransferableTypedData.fromList(<Uint8List>[encodedFrame]),
      ),
    );
    return completer.future;
  }

  /// Closes one specific `/transfer` channel by [channelId].
  void closeChannel(int channelId, {String reason = 'local_closed'}) {
    _worker?.send(_CloseChannel(channelId: channelId, reason: reason));
  }

  /// Closes every `/transfer` channel belonging to [peerId] (or only those
  /// matching [connectionGeneration] when supplied).
  void closePeer(
    String peerId, {
    int? connectionGeneration,
    TransferChannelKind? kind,
    String reason = 'peer_closed',
  }) {
    _worker?.send(
      _ClosePeerChannels(
        peerId: peerId,
        connectionGeneration: connectionGeneration,
        kind: kind,
        reason: reason,
      ),
    );
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _port = 0;
    final worker = _worker;
    _worker = null;
    worker?.send(const _ShutdownWorker());
    for (final completer in _pendingDials.values) {
      if (!completer.isCompleted) {
        completer.complete(const TransferDataDialResult(ok: false));
      }
    }
    _pendingDials.clear();
    for (final completer in _pendingSends.values) {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }
    _pendingSends.clear();
    for (final pending in _pendingClaims.values) {
      pending.release();
    }
    _pendingClaims.clear();
    _receive?.close();
    _receive = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  void _handleWorkerMessage(Object? message) {
    switch (message) {
      case _DialResult():
        final completer = _pendingDials.remove(message.requestId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(
            TransferDataDialResult(
              ok: message.ok,
              channelId: message.channelId,
              unreachable: message.unreachable,
            ),
          );
        }
      case _SendAck():
        final completer = _pendingSends.remove(message.requestId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(message.ok);
        }
      case _ChannelOpened():
        onChannelOpened(
          TransferDataChannelOpened(
            channelId: message.channelId,
            peerId: message.peerId,
            connectionGeneration: message.connectionGeneration,
            kind: message.kind,
            sessionId: message.sessionId,
            reverse: message.reverse,
          ),
        );
      case _ChannelClosed():
        onChannelClosed(
          TransferDataChannelClosed(
            channelId: message.channelId,
            peerId: message.peerId,
            connectionGeneration: message.connectionGeneration,
            kind: message.kind,
            expected: message.expected,
            reason: message.reason,
          ),
        );
      case _InboundFrame():
        final bytes = message.data.materialize().asUint8List();
        final byteCount = bytes.length;
        final delivery = onInboundFrame(
          TransferDataInboundFrame(
            channelId: message.channelId,
            peerId: message.peerId,
            connectionGeneration: message.connectionGeneration,
            kind: message.kind,
            bytes: bytes,
          ),
        );
        void returnCredit() {
          if (!_closed) {
            _worker?.send(
              _InboundCredit(channelId: message.channelId, bytes: byteCount),
            );
          }
        }
        if (delivery is Future<void>) {
          unawaited(delivery.whenComplete(returnCredit));
        } else {
          returnCredit();
        }
      case _LookupClaim():
        _handleLookupClaim(message);
      case _ConsumeClaim():
        _handleConsumeClaim(message);
      case _ReleaseClaim():
        _pendingClaims.remove(message.requestId)?.release();
      default:
        break;
    }
  }

  void _handleLookupClaim(_LookupClaim lookup) {
    final result = claimBroker.lookup(
      sessionId: lookup.sessionId,
      token: lookup.token,
      remoteAddress: lookup.remoteAddress,
    );
    if (result == null || result.claim.isDestroyed) {
      result?.destroy();
      _worker?.send(_ClaimAnswer(lookup.requestId, null));
      return;
    }
    final expires = Timer(const Duration(seconds: 10), () {
      _pendingClaims.remove(lookup.requestId)?.release();
    });
    _pendingClaims[lookup.requestId] = _PendingClaim(
      result: result,
      sessionId: lookup.sessionId,
      token: lookup.token,
      expires: expires,
    );
    final data = result.claim.withMediaPacketContext(
      (receiveKey, channelBinding) => _ClaimData(
        requestId: lookup.requestId,
        sessionId: result.claim.sessionId,
        peerId: result.claim.peerId,
        connectionGeneration: result.claim.connectionGeneration,
        kind: result.kind,
        reverse: result.claim.reverse,
        receiveKey: Uint8List.fromList(receiveKey),
        sendKey: Uint8List.fromList(result.sendKey),
        channelBinding: Uint8List.fromList(channelBinding),
      ),
    );
    _worker?.send(_ClaimAnswer(lookup.requestId, data));
  }

  void _handleConsumeClaim(_ConsumeClaim consume) {
    final pending = _pendingClaims.remove(consume.requestId);
    if (pending == null) {
      _worker?.send(_ConsumeAnswer(consume.requestId, false));
      return;
    }
    final ok = claimBroker.consume(
      sessionId: pending.sessionId,
      token: pending.token,
      expected: pending.result.claim,
    );
    pending.release();
    _worker?.send(_ConsumeAnswer(consume.requestId, ok));
  }
}

final class _PendingClaim {
  _PendingClaim({
    required this.result,
    required this.sessionId,
    required this.token,
    required this.expires,
  });

  final TransferClaimLookupResult result;
  final String sessionId;
  final String token;
  final Timer expires;

  void release() {
    expires.cancel();
    result.destroy();
  }
}

// ---------------------------------------------------------------------------
// Isolate messages
// ---------------------------------------------------------------------------

final class _IsolateStart {
  const _IsolateStart(this.main, this.preferredPort);

  final SendPort main;
  final int preferredPort;
}

final class _WorkerReady {
  const _WorkerReady(this.sendPort, this.port);

  final SendPort sendPort;
  final int port;
}

final class _WorkerStartFailed {
  const _WorkerStartFailed(this.reason);

  final String reason;
}

final class _ShutdownWorker {
  const _ShutdownWorker();
}

final class _DialChannel {
  const _DialChannel({
    required this.requestId,
    required this.host,
    required this.port,
    required this.sessionId,
    required this.token,
    required this.localPeerId,
    required this.remotePeerId,
    required this.connectionGeneration,
    required this.kind,
    required this.reverse,
    required this.sendKey,
    required this.receiveKey,
    required this.connectTimeoutMicros,
  });

  final int requestId;
  final String host;
  final int port;
  final String sessionId;
  final String token;
  final String localPeerId;
  final String remotePeerId;
  final int connectionGeneration;
  final TransferChannelKind kind;
  final bool reverse;
  final Uint8List sendKey;
  final Uint8List receiveKey;
  final int connectTimeoutMicros;
}

final class _DialResult {
  const _DialResult(
    this.requestId, {
    required this.ok,
    this.channelId,
    this.unreachable = false,
  });

  final int requestId;
  final bool ok;
  final int? channelId;
  final bool unreachable;
}

final class _SendFrame {
  const _SendFrame({
    required this.requestId,
    required this.channelId,
    required this.data,
  });

  final int requestId;
  final int channelId;
  final TransferableTypedData data;
}

final class _SendAck {
  const _SendAck(this.requestId, this.ok);

  final int requestId;
  final bool ok;
}

final class _InboundFrame {
  const _InboundFrame({
    required this.channelId,
    required this.peerId,
    required this.connectionGeneration,
    required this.kind,
    required this.data,
  });

  final int channelId;
  final String peerId;
  final int connectionGeneration;
  final TransferChannelKind kind;
  final TransferableTypedData data;
}

final class _InboundCredit {
  const _InboundCredit({required this.channelId, required this.bytes});

  final int channelId;
  final int bytes;
}

final class _ChannelOpened {
  const _ChannelOpened({
    required this.channelId,
    required this.peerId,
    required this.connectionGeneration,
    required this.kind,
    required this.sessionId,
    required this.reverse,
  });

  final int channelId;
  final String peerId;
  final int connectionGeneration;
  final TransferChannelKind kind;
  final String sessionId;
  final bool reverse;
}

final class _ChannelClosed {
  const _ChannelClosed({
    required this.channelId,
    required this.peerId,
    required this.connectionGeneration,
    required this.kind,
    required this.expected,
    required this.reason,
  });

  final int channelId;
  final String peerId;
  final int connectionGeneration;
  final TransferChannelKind kind;
  final bool expected;
  final String reason;
}

final class _CloseChannel {
  const _CloseChannel({required this.channelId, required this.reason});

  final int channelId;
  final String reason;
}

final class _ClosePeerChannels {
  const _ClosePeerChannels({
    required this.peerId,
    this.connectionGeneration,
    this.kind,
    required this.reason,
  });

  final String peerId;
  final int? connectionGeneration;
  final TransferChannelKind? kind;
  final String reason;
}

final class _LookupClaim {
  const _LookupClaim(
    this.requestId,
    this.sessionId,
    this.token,
    this.remoteAddress,
  );

  final int requestId;
  final String sessionId;
  final String token;
  final String remoteAddress;
}

final class _ClaimData {
  const _ClaimData({
    required this.requestId,
    required this.sessionId,
    required this.peerId,
    required this.connectionGeneration,
    required this.kind,
    required this.reverse,
    required this.receiveKey,
    required this.sendKey,
    required this.channelBinding,
  });

  final int requestId;
  final String sessionId;
  final String peerId;
  final int connectionGeneration;
  final TransferChannelKind kind;
  final bool reverse;
  final Uint8List receiveKey;
  final Uint8List sendKey;
  final Uint8List channelBinding;

  void zeroKeys() {
    receiveKey.fillRange(0, receiveKey.length, 0);
    sendKey.fillRange(0, sendKey.length, 0);
    channelBinding.fillRange(0, channelBinding.length, 0);
  }
}

final class _ClaimAnswer {
  const _ClaimAnswer(this.requestId, this.claim);

  final int requestId;
  final _ClaimData? claim;
}

final class _ConsumeClaim {
  const _ConsumeClaim(this.requestId);

  final int requestId;
}

final class _ConsumeAnswer {
  const _ConsumeAnswer(this.requestId, this.consumed);

  final int requestId;
  final bool consumed;
}

final class _ReleaseClaim {
  const _ReleaseClaim(this.requestId);

  final int requestId;
}
