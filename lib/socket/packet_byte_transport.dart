import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

enum PacketSendResult { sent, dropped, closed, transportFailure }

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
  })  : _sendBytes = sendBytes,
        _closeSink = closeSink,
        _queue = null;

  PacketByteTransport.audio({
    required Future<void> Function(Stream<Object>) addStream,
    required Future<void> Function() closeSink,
    this.onPacketSent,
    this.onPacketDropped,
    int maxItems = 32,
    int maxBytes = 512 * 1024,
    this.packetEncoder,
  })  : _sendBytes = null,
        _closeSink = closeSink,
        _queue = BoundedOutboundQueue.audio(
          addStream: addStream,
          maxItems: maxItems,
          maxBytes: maxBytes,
        );

  PacketByteTransport.remoteInput({
    required Future<void> Function(Stream<Object>) addStream,
    required Future<void> Function() closeSink,
    this.onPacketSent,
    this.onPacketDropped,
    void Function()? onOverflow,
    int maxItems = 128,
    int maxBytes = 256 * 1024,
    this.packetEncoder,
  })  : _sendBytes = null,
        _closeSink = closeSink,
        _queue = BoundedOutboundQueue.remoteInput(
          addStream: addStream,
          maxItems: maxItems,
          maxBytes: maxBytes,
          onOverflow: onOverflow,
        );

  final void Function(Object bytes)? _sendBytes;
  final Future<void> Function() _closeSink;
  final BoundedOutboundQueue? _queue;
  final void Function()? onPacketSent;
  final void Function()? onPacketDropped;
  final AuthenticatedMediaPacketEncoder? packetEncoder;
  bool _closed = false;
  Future<void>? _closeFuture;

  bool get isClosed => _closed;

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
      _sendBytes!(_encodePacket(bytes));
      onPacketSent?.call();
      return Future<PacketSendResult>.value(PacketSendResult.sent);
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
      return switch (result) {
        OutboundQueueResult.sent => PacketSendResult.sent,
        OutboundQueueResult.dropped => PacketSendResult.dropped,
        OutboundQueueResult.closed => PacketSendResult.closed,
        OutboundQueueResult.writerFailure => PacketSendResult.transportFailure,
      };
    });
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closed = true;
    return _closeFuture = () async {
      await _queue?.closeAndDrain();
      await _closeSink();
    }();
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
  int remoteInputMaxItems = 128,
  int remoteInputMaxBytes = 256 * 1024,
}) async {
  final PacketWebSocketConnection connection;
  try {
    if (connector == null) {
      final channel = IOWebSocketChannel.connect(uri);
      await channel.ready;
      connection = (
        addStream: channel.sink.addStream,
        closeSink: () => channel.sink.close(),
      );
    } else {
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
      onOverflow: () {
        unawaited(connection.closeSink().catchError((Object _) {}));
      },
    );
  }
  return PacketByteTransport.audio(
    addStream: connection.addStream,
    closeSink: connection.closeSink,
    packetEncoder: packetEncoder,
  );
}
