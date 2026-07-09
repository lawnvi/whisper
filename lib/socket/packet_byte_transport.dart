import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/bounded_outbound_queue.dart';

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
      _sendBytes!(bytes);
      onPacketSent?.call();
      return Future<PacketSendResult>.value(PacketSendResult.sent);
    }
    return queue
        .addWithResult(
      bytes,
      byteLength: _byteLength(bytes),
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
}) {
  return Uri(
    scheme: 'ws',
    host: host,
    port: port,
    path: path.startsWith('/') ? path.substring(1) : path,
  );
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
  int remoteInputMaxItems = 128,
  int remoteInputMaxBytes = 256 * 1024,
}) async {
  final PacketWebSocketConnection connection;
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
  if (uri.path == '/input') {
    return PacketByteTransport.remoteInput(
      addStream: connection.addStream,
      closeSink: connection.closeSink,
      maxItems: remoteInputMaxItems,
      maxBytes: remoteInputMaxBytes,
      onOverflow: () {
        unawaited(connection.closeSink().catchError((Object _) {}));
      },
    );
  }
  return PacketByteTransport.audio(
    addStream: connection.addStream,
    closeSink: connection.closeSink,
  );
}
