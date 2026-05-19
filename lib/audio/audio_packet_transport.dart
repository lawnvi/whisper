import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';

abstract class AudioPacketTransport {
  void send(AudioPacketFrame packet);

  Future<void> close();
}

class AudioPacketByteTransport implements AudioPacketTransport {
  AudioPacketByteTransport({
    required void Function(Uint8List bytes) sendBytes,
    Future<void> Function()? closeSink,
    AudioShareDiagnostics? diagnostics,
  })  : _sendBytes = sendBytes,
        _closeSink = closeSink,
        _diagnostics = diagnostics ?? AudioShareDiagnostics.shared;

  final void Function(Uint8List bytes) _sendBytes;
  final Future<void> Function()? _closeSink;
  final AudioShareDiagnostics _diagnostics;
  bool _closed = false;

  @override
  void send(AudioPacketFrame packet) {
    if (_closed) {
      _diagnostics.audioPacketSendDropped(
        sessionId: packet.sessionId,
        sequence: packet.sequence,
        reason: 'closed',
      );
      return;
    }
    _sendBytes(packet.encode());
    _diagnostics.audioPacketSent(
      sessionId: packet.sessionId,
      sequence: packet.sequence,
      payloadBytes: packet.payload.length,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _closeSink?.call();
  }
}

class AudioWebSocketPacketTransport extends AudioPacketByteTransport {
  AudioWebSocketPacketTransport._(
    WebSocketChannel channel, {
    required AudioShareDiagnostics diagnostics,
  })  : _channel = channel,
        super(
          sendBytes: channel.sink.add,
          closeSink: () => channel.sink.close(),
          diagnostics: diagnostics,
        );

  final WebSocketChannel _channel;

  static Future<AudioWebSocketPacketTransport> connect(
    Uri uri, {
    AudioShareDiagnostics? diagnostics,
  }) async {
    final resolvedDiagnostics = diagnostics ?? AudioShareDiagnostics.shared;
    resolvedDiagnostics.transportConnecting(uri);
    try {
      final channel = IOWebSocketChannel.connect(uri);
      await channel.ready;
      resolvedDiagnostics.transportConnected(uri);
      return AudioWebSocketPacketTransport._(
        channel,
        diagnostics: resolvedDiagnostics,
      );
    } catch (error) {
      resolvedDiagnostics.transportConnectFailed(uri, error);
      rethrow;
    }
  }

  Stream<dynamic> get stream => _channel.stream;
}
