import 'dart:typed_data';

import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

abstract class AudioPacketTransport {
  void send(AudioPacketFrame packet);

  Future<void> close();
}

class AudioPacketByteTransport implements AudioPacketTransport {
  AudioPacketByteTransport({
    required void Function(Uint8List bytes) sendBytes,
    Future<void> Function()? closeSink,
    AudioShareDiagnostics? diagnostics,
  }) : _diagnostics = diagnostics ?? AudioShareDiagnostics.shared {
    _inner = PacketByteTransport(
      sendBytes: (bytes) => sendBytes(bytes as Uint8List),
      closeSink: closeSink ?? () async {},
      onPacketSent: _emitSent,
      onPacketDropped: _emitDropped,
    );
  }

  final AudioShareDiagnostics _diagnostics;
  late final PacketByteTransport _inner;
  AudioPacketFrame? _pending;

  void _emitSent() {
    final packet = _pending!;
    _diagnostics.audioPacketSent(
      sessionId: packet.sessionId,
      sequence: packet.sequence,
      payloadBytes: packet.payload.length,
    );
  }

  void _emitDropped() {
    final packet = _pending!;
    _diagnostics.audioPacketSendDropped(
      sessionId: packet.sessionId,
      sequence: packet.sequence,
      reason: 'closed',
    );
  }

  @override
  void send(AudioPacketFrame packet) {
    _pending = packet;
    _inner.send(_inner.isClosed ? Uint8List(0) : packet.encode());
  }

  @override
  Future<void> close() => _inner.close();
}

class AudioWebSocketPacketTransport extends AudioPacketByteTransport {
  AudioWebSocketPacketTransport._(
    PacketByteTransport channelTransport, {
    required AudioShareDiagnostics diagnostics,
  }) : super(
          sendBytes: (bytes) => channelTransport.send(bytes),
          closeSink: channelTransport.close,
          diagnostics: diagnostics,
        );

  static Future<AudioWebSocketPacketTransport> connect(
    Uri uri, {
    AudioShareDiagnostics? diagnostics,
  }) async {
    final resolvedDiagnostics = diagnostics ?? AudioShareDiagnostics.shared;
    resolvedDiagnostics.transportConnecting(uri);
    try {
      final channelTransport = await connectPacketWebSocket(uri);
      resolvedDiagnostics.transportConnected(uri);
      return AudioWebSocketPacketTransport._(
        channelTransport,
        diagnostics: resolvedDiagnostics,
      );
    } catch (error) {
      resolvedDiagnostics.transportConnectFailed(uri, error);
      rethrow;
    }
  }
}
