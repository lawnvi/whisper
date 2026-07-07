import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Shared byte-transport core for the three packet-transport subsystems
/// (audio / audio group / remote input): close is idempotent, `send` after
/// close silently drops (with an optional hook), and `done` broadcasts a
/// one-time notification (no subscribers => zero overhead).
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
  final StreamController<void> _done = StreamController<void>.broadcast();
  bool _closed = false;
  bool _doneNotified = false;

  bool get isClosed => _closed;
  Stream<void> get done => _done.stream;

  void send(Object bytes) {
    if (_closed) {
      onPacketDropped?.call();
      return;
    }
    _sendBytes(bytes);
    onPacketSent?.call();
  }

  /// WS onDone/onError 或 close() 时触发,一次性。
  void notifyDone() {
    if (_doneNotified) {
      return;
    }
    _doneNotified = true;
    if (!_done.isClosed) {
      _done.add(null);
    }
    unawaited(_done.close());
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _closeSink();
    notifyDone();
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
/// + `await channel.ready`) and the try/catch + rethrow shape are taken as-is
/// from the prior `AudioWebSocketPacketTransport.connect` implementation;
/// subsystem-specific diagnostics are generalized to the optional [log]
/// callback so this helper stays subsystem-agnostic.
Future<PacketByteTransport> connectPacketWebSocket(
  Uri uri, {
  void Function(String message)? log,
  void Function()? onPacketSent,
  void Function()? onPacketDropped,
}) async {
  log?.call('connecting uri=$uri');
  try {
    final channel = IOWebSocketChannel.connect(uri);
    await channel.ready;
    log?.call('connected uri=$uri');
    return PacketByteTransport(
      sendBytes: channel.sink.add,
      closeSink: () => channel.sink.close(),
      onPacketSent: onPacketSent,
      onPacketDropped: onPacketDropped,
    );
  } catch (error) {
    log?.call('connect failed uri=$uri error=$error');
    rethrow;
  }
}
