import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/transport_close_guard.dart';

enum PacketSendResult { sent, dropped, closed, transportFailure }

enum PacketTransportTerminationReason {
  localClosed,
  remoteClosed,
  remoteError,
  writerFailure,
}

final class PacketTransportTermination {
  const PacketTransportTermination(this.reason, {this.error});

  final PacketTransportTerminationReason reason;
  final Object? error;

  bool get isUnexpected =>
      reason != PacketTransportTerminationReason.localClosed;
}

/// Shared byte-transport core for the three packet-transport subsystems
/// (audio / audio group / remote input): close is idempotent and `send` after
/// close silently drops (with an optional hook).
///
/// Extracted so `AudioPacketByteTransport` / `AudioGroupPacketByteTransport` /
/// `RemoteInputPacketByteTransport` delegate the closed-guard + send/close
/// bookkeeping to one implementation instead of each carrying a byte-identical
/// copy. See test/packet_byte_transport_test.dart for the behavior contract.
class PacketByteTransport {
  PacketByteTransport({
    required void Function(Object bytes) sendBytes,
    required Future<void> Function() closeSink,
    this.onPacketSent,
    this.onPacketDropped,
    this.packetEncoder,
    Duration closeTimeout = const Duration(seconds: 2),
  })  : _sendBytes = sendBytes,
        _closeGuard = TransportCloseGuard(
          close: closeSink,
          timeout: closeTimeout,
        ),
        _queue = null;

  PacketByteTransport.audio({
    required Future<void> Function(Stream<Object>) addStream,
    required Future<void> Function() closeSink,
    Stream<dynamic>? incoming,
    this.onPacketSent,
    this.onPacketDropped,
    int maxItems = 32,
    int maxBytes = 512 * 1024,
    Duration writerTimeout = const Duration(seconds: 2),
    Duration closeTimeout = const Duration(seconds: 2),
    this.packetEncoder,
  })  : _sendBytes = null,
        _closeGuard = TransportCloseGuard(
          close: closeSink,
          timeout: closeTimeout,
        ),
        _queue = BoundedOutboundQueue.audio(
          addStream: addStream,
          maxItems: maxItems,
          maxBytes: maxBytes,
          writerTimeout: writerTimeout,
        ) {
    _observeIncoming(incoming);
  }

  PacketByteTransport.remoteInput({
    required Future<void> Function(Stream<Object>) addStream,
    required Future<void> Function() closeSink,
    this.onPacketSent,
    this.onPacketDropped,
    void Function()? onOverflow,
    int maxItems = 128,
    int maxBytes = 256 * 1024,
    Duration writerTimeout = const Duration(seconds: 2),
    Duration closeTimeout = const Duration(seconds: 2),
    this.packetEncoder,
  })  : _sendBytes = null,
        _closeGuard = TransportCloseGuard(
          close: closeSink,
          timeout: closeTimeout,
        ),
        _queue = BoundedOutboundQueue.remoteInput(
          addStream: addStream,
          maxItems: maxItems,
          maxBytes: maxBytes,
          writerTimeout: writerTimeout,
          onOverflow: onOverflow,
        );

  final void Function(Object bytes)? _sendBytes;
  final TransportCloseGuard _closeGuard;
  final BoundedOutboundQueue? _queue;
  final void Function()? onPacketSent;
  final void Function()? onPacketDropped;
  final AuthenticatedMediaPacketEncoder? packetEncoder;
  final Completer<PacketTransportTermination> _doneCompleter =
      Completer<PacketTransportTermination>();
  StreamSubscription<dynamic>? _incomingSubscription;
  bool _closed = false;
  Future<void>? _closeFuture;

  bool get isClosed => _closed;
  Future<PacketTransportTermination> get done => _doneCompleter.future;

  Future<PacketSendResult> send(
    Object bytes, {
    OutboundPacketKind kind = OutboundPacketKind.audio,
  }) {
    if (_closed) {
      onPacketDropped?.call();
      return Future<PacketSendResult>.value(PacketSendResult.closed);
    }
    final queue = _queue;
    if (queue == null) {
      try {
        _sendBytes!(_encodePacket(bytes));
        onPacketSent?.call();
        return Future<PacketSendResult>.value(PacketSendResult.sent);
      } catch (error, stackTrace) {
        _terminateUnexpected(
          PacketTransportTermination(
            PacketTransportTerminationReason.writerFailure,
            error: error,
          ),
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    return queue
        .addLazyWithResult(
      () async => _encodePacket(bytes),
      byteLength: _byteLength(bytes) +
          (packetEncoder == null
              ? 0
              : AuthenticatedMediaPacketEnvelope.overheadBytes),
      kind: kind,
    )
        .then((result) {
      if (result == OutboundQueueResult.sent) {
        onPacketSent?.call();
      } else {
        onPacketDropped?.call();
      }
      if (result == OutboundQueueResult.writerFailure) {
        _terminateUnexpected(
          PacketTransportTermination(
            PacketTransportTerminationReason.writerFailure,
            error: StateError('packet transport writer failed'),
          ),
        );
      } else if (result == OutboundQueueResult.dropped && queue.isClosed) {
        _terminateUnexpected(
          const PacketTransportTermination(
            PacketTransportTerminationReason.writerFailure,
          ),
        );
      }
      return switch (result) {
        OutboundQueueResult.sent => PacketSendResult.sent,
        OutboundQueueResult.dropped => PacketSendResult.dropped,
        OutboundQueueResult.closed => PacketSendResult.closed,
        OutboundQueueResult.writerFailure => PacketSendResult.transportFailure,
      };
    });
  }

  Future<void> close() => _beginClose(
        const PacketTransportTermination(
          PacketTransportTerminationReason.localClosed,
        ),
      );

  void _observeIncoming(Stream<dynamic>? incoming) {
    if (incoming == null) {
      return;
    }
    _incomingSubscription = incoming.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _terminateUnexpected(
          PacketTransportTermination(
            PacketTransportTerminationReason.remoteError,
            error: error,
          ),
        );
      },
      onDone: () {
        _terminateUnexpected(
          const PacketTransportTermination(
            PacketTransportTerminationReason.remoteClosed,
          ),
        );
      },
      cancelOnError: false,
    );
  }

  void _terminateUnexpected(PacketTransportTermination termination) {
    if (_closed) {
      return;
    }
    unawaited(
      _beginClose(termination).catchError((Object _, StackTrace __) {}),
    );
  }

  Future<void> _beginClose(PacketTransportTermination termination) {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closed = true;
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete(termination);
    }
    final completer = Completer<void>();
    final closeFuture = completer.future;
    _closeFuture = closeFuture;
    final subscription = _incomingSubscription;
    _incomingSubscription = null;
    unawaited(() async {
      await subscription?.cancel();
      if (termination.isUnexpected) {
        _queue?.abort();
        await _closeGuard.close();
      } else {
        await _queue?.closeAndDrain();
        await _closeGuard.close();
      }
    }()
        .then<void>(
      (_) => completer.complete(),
      onError: (Object error, StackTrace stackTrace) =>
          completer.completeError(error, stackTrace),
    ));
    return closeFuture;
  }

  Object _encodePacket(Object bytes) {
    final encoder = packetEncoder;
    if (encoder == null) {
      return bytes;
    }
    if (bytes is! List<int>) {
      throw const FormatException('binary media packet required');
    }
    return encoder.encode(Uint8List.fromList(bytes));
  }
}

int _byteLength(Object bytes) {
  if (bytes is List<int>) {
    return bytes.length;
  }
  if (bytes is String) {
    return bytes.length;
  }
  return 0;
}

/// Composes the `ws://host:port/path` URI shared by the audio / audio-group /
/// remote-input peer packet transports. Callers resolve any subsystem-specific
/// default path (e.g. `/audio`, `/input`) before calling this — the function
/// itself only normalizes the leading slash, matching
/// `audio_share_coordinator.dart`'s prior `_audioUri`.
Uri buildPeerPacketUri({
  required String host,
  required int port,
  required String path,
  Map<String, String> queryParameters = const <String, String>{},
}) {
  return Uri(
    scheme: 'ws',
    host: host,
    port: port,
    path: path.startsWith('/') ? path.substring(1) : path,
    queryParameters: queryParameters.isEmpty ? null : queryParameters,
  );
}

Uri redactedPacketUri(Uri uri) {
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: Uri.decodeComponent(uri.host),
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  );
}

final class PacketWebSocketConnectException implements Exception {
  PacketWebSocketConnectException(Uri uri, Object cause)
      : uri = redactedPacketUri(uri),
        causeType = cause.runtimeType.toString();

  final Uri uri;
  final String causeType;

  @override
  String toString() =>
      'Packet WebSocket connection failed: $uri (cause: $causeType)';
}

abstract final class AuthenticatedMediaPacketEnvelope {
  static const int sequenceOffset = 4;
  static const int payloadLengthOffset = 12;
  static const int macOffset = 16;
  static const int macBytes = 32;
  static const int overheadBytes = macOffset + macBytes;
  static const List<int> magic = <int>[0x57, 0x4d, 0x50, 0x31];
}

final class AuthenticatedMediaPacketEncoder {
  AuthenticatedMediaPacketEncoder({
    required String route,
    required this.sessionId,
    required Uint8List mediaMacKey,
    required this.maxPayloadBytes,
  })  : route = normalizeMediaRoute(route),
        _mediaMacKey = Uint8List.fromList(mediaMacKey) {
    _validateMediaPacketContext(
      sessionId: sessionId,
      mediaMacKey: mediaMacKey,
      maxPayloadBytes: maxPayloadBytes,
    );
  }

  final String route;
  final String sessionId;
  final int maxPayloadBytes;
  final Uint8List _mediaMacKey;
  int _nextSequence = 0;

  int get nextSequence => _nextSequence;

  Uint8List encode(Uint8List payload) {
    if (payload.length > maxPayloadBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload.length',
        'exceeds $maxPayloadBytes',
      );
    }
    final sequence = _nextSequence;
    final mac = _mediaPacketMac(
      route: route,
      sessionId: sessionId,
      sequence: sequence,
      payload: payload,
      mediaMacKey: _mediaMacKey,
    );
    final encoded = Uint8List(
      AuthenticatedMediaPacketEnvelope.overheadBytes + payload.length,
    );
    encoded.setRange(
      0,
      AuthenticatedMediaPacketEnvelope.magic.length,
      AuthenticatedMediaPacketEnvelope.magic,
    );
    final data = ByteData.sublistView(encoded);
    data.setUint64(
      AuthenticatedMediaPacketEnvelope.sequenceOffset,
      sequence,
    );
    data.setUint32(
      AuthenticatedMediaPacketEnvelope.payloadLengthOffset,
      payload.length,
    );
    encoded.setRange(
      AuthenticatedMediaPacketEnvelope.macOffset,
      AuthenticatedMediaPacketEnvelope.overheadBytes,
      mac,
    );
    encoded.setRange(
      AuthenticatedMediaPacketEnvelope.overheadBytes,
      encoded.length,
      payload,
    );
    _nextSequence += 1;
    return encoded;
  }
}

final class AuthenticatedMediaPacketDecoder {
  AuthenticatedMediaPacketDecoder({
    required String route,
    required this.sessionId,
    required Uint8List mediaMacKey,
    required this.maxPayloadBytes,
  })  : route = normalizeMediaRoute(route),
        _mediaMacKey = Uint8List.fromList(mediaMacKey) {
    _validateMediaPacketContext(
      sessionId: sessionId,
      mediaMacKey: mediaMacKey,
      maxPayloadBytes: maxPayloadBytes,
    );
  }

  final String route;
  final String sessionId;
  final int maxPayloadBytes;
  final Uint8List _mediaMacKey;
  int _expectedSequence = 0;

  int get expectedSequence => _expectedSequence;

  Uint8List decode(Uint8List encoded) {
    if (encoded.length < AuthenticatedMediaPacketEnvelope.overheadBytes) {
      throw const FormatException('media packet envelope truncated');
    }
    if (!constantTimeBytesEqual(
      Uint8List.sublistView(
        encoded,
        0,
        AuthenticatedMediaPacketEnvelope.magic.length,
      ),
      AuthenticatedMediaPacketEnvelope.magic,
    )) {
      throw const FormatException('invalid media packet envelope');
    }
    final data = ByteData.sublistView(encoded);
    final sequence = data.getUint64(
      AuthenticatedMediaPacketEnvelope.sequenceOffset,
    );
    final payloadLength = data.getUint32(
      AuthenticatedMediaPacketEnvelope.payloadLengthOffset,
    );
    if (payloadLength > maxPayloadBytes ||
        encoded.length !=
            AuthenticatedMediaPacketEnvelope.overheadBytes + payloadLength) {
      throw const FormatException('invalid media packet payload length');
    }
    final payload = Uint8List.sublistView(
      encoded,
      AuthenticatedMediaPacketEnvelope.overheadBytes,
    );
    final suppliedMac = Uint8List.sublistView(
      encoded,
      AuthenticatedMediaPacketEnvelope.macOffset,
      AuthenticatedMediaPacketEnvelope.overheadBytes,
    );
    final expectedMac = _mediaPacketMac(
      route: route,
      sessionId: sessionId,
      sequence: sequence,
      payload: payload,
      mediaMacKey: _mediaMacKey,
    );
    if (!constantTimeBytesEqual(suppliedMac, expectedMac)) {
      throw const FormatException('invalid media packet MAC');
    }
    if (sequence != _expectedSequence) {
      throw const FormatException('invalid media packet sequence');
    }
    _expectedSequence += 1;
    return Uint8List.fromList(payload);
  }
}

void _validateMediaPacketContext({
  required String sessionId,
  required Uint8List mediaMacKey,
  required int maxPayloadBytes,
}) {
  if (sessionId.isEmpty) {
    throw ArgumentError.value(sessionId, 'sessionId');
  }
  if (mediaMacKey.length != 32) {
    throw ArgumentError.value(mediaMacKey.length, 'mediaMacKey.length');
  }
  if (maxPayloadBytes <= 0) {
    throw ArgumentError.value(maxPayloadBytes, 'maxPayloadBytes');
  }
}

Uint8List _mediaPacketMac({
  required String route,
  required String sessionId,
  required int sequence,
  required Uint8List payload,
  required Uint8List mediaMacKey,
}) {
  final domain = utf8.encode('whisper-media-packet-v1\u0000');
  final routeBytes = utf8.encode(route);
  final sessionBytes = utf8.encode(sessionId);
  if (routeBytes.length > 0xffff || sessionBytes.length > 0xffff) {
    throw const FormatException('media packet context is too long');
  }
  final input = Uint8List(
    domain.length +
        2 +
        routeBytes.length +
        2 +
        sessionBytes.length +
        8 +
        4 +
        payload.length,
  );
  var offset = 0;
  input.setRange(offset, offset + domain.length, domain);
  offset += domain.length;
  final data = ByteData.sublistView(input);
  data.setUint16(offset, routeBytes.length);
  offset += 2;
  input.setRange(offset, offset + routeBytes.length, routeBytes);
  offset += routeBytes.length;
  data.setUint16(offset, sessionBytes.length);
  offset += 2;
  input.setRange(offset, offset + sessionBytes.length, sessionBytes);
  offset += sessionBytes.length;
  data.setUint64(offset, sequence);
  offset += 8;
  data.setUint32(offset, payload.length);
  offset += 4;
  input.setRange(offset, input.length, payload);
  return Uint8List.fromList(Hmac(sha256, mediaMacKey).convert(input).bytes);
}

typedef PacketWebSocketConnection = ({
  Future<void> Function(Stream<Object>) addStream,
  Future<void> Function() closeSink,
});
typedef PacketWebSocketConnector = Future<PacketWebSocketConnection> Function(
  Uri uri,
);

/// Connects a `WebSocketChannel` to [uri] and wraps it in a
/// [PacketByteTransport]. Channel establishment (`IOWebSocketChannel.connect`
/// + `await channel.ready`) is taken as-is from the prior
/// `AudioWebSocketPacketTransport.connect` implementation; a failed
/// `channel.ready` propagates to the caller, which owns any diagnostics/retry.
Future<PacketByteTransport> connectPacketWebSocket(
  Uri uri, {
  PacketWebSocketConnector? connector,
  AuthenticatedMediaPacketEncoder? packetEncoder,
  MediaUpgradeClientContext? mediaUpgradeContext,
  int remoteInputMaxItems = 128,
  int remoteInputMaxBytes = 256 * 1024,
}) async {
  final PacketWebSocketConnection connection;
  Stream<dynamic>? incoming;
  try {
    if (connector == null) {
      WebSocketChannel channel = IOWebSocketChannel.connect(uri);
      await channel.ready;
      if (mediaUpgradeContext case final context?) {
        channel = await authenticateMediaWebSocketClient(
          channel,
          uri: uri,
          route: uri.path,
          namespace: context.namespace,
          sessionId: context.sessionId,
          peerId: context.peerId,
          mediaMacKey: context.mediaMacKey,
          timeout: context.timeout,
        );
      }
      incoming = channel.stream;
      connection = (
        addStream: channel.sink.addStream,
        closeSink: () => channel.sink.close(),
      );
    } else {
      if (mediaUpgradeContext != null) {
        throw UnsupportedError(
          'custom packet websocket connectors cannot skip media proof',
        );
      }
      connection = await connector(uri);
    }
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(
      error is PacketWebSocketConnectException
          ? error
          : PacketWebSocketConnectException(uri, error),
      stackTrace,
    );
  }
  if (uri.path == '/input') {
    return PacketByteTransport.remoteInput(
      addStream: connection.addStream,
      closeSink: connection.closeSink,
      maxItems: remoteInputMaxItems,
      maxBytes: remoteInputMaxBytes,
      packetEncoder: packetEncoder,
    );
  }
  return PacketByteTransport.audio(
    addStream: connection.addStream,
    closeSink: connection.closeSink,
    incoming: incoming,
    packetEncoder: packetEncoder,
  );
}
