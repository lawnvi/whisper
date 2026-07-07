import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
        _closeSink = closeSink;

  final void Function(Object bytes) _sendBytes;
  final Future<void> Function() _closeSink;
  final void Function()? onPacketSent;
  final void Function()? onPacketDropped;
  bool _closed = false;

  bool get isClosed => _closed;

  void send(Object bytes) {
    if (_closed) {
      onPacketDropped?.call();
      return;
    }
    _sendBytes(bytes);
    onPacketSent?.call();
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _closeSink();
  }
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

/// Connects a `WebSocketChannel` to [uri] and wraps it in a
/// [PacketByteTransport]. Channel establishment (`IOWebSocketChannel.connect`
/// + `await channel.ready`) is taken as-is from the prior
/// `AudioWebSocketPacketTransport.connect` implementation; a failed
/// `channel.ready` propagates to the caller, which owns any diagnostics/retry.
Future<PacketByteTransport> connectPacketWebSocket(Uri uri) async {
  final channel = IOWebSocketChannel.connect(uri);
  await channel.ready;
  return PacketByteTransport(
    sendBytes: channel.sink.add,
    closeSink: () => channel.sink.close(),
  );
}
