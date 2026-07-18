import 'dart:async';
import 'dart:typed_data';

import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';
import 'package:whisper/socket/media_upgrade_proof.dart';
import 'package:whisper/socket/packet_byte_transport.dart';

abstract class AudioPacketTransport {
  void send(AudioPacketFrame packet);

  Future<void> close();
}

abstract class AudioObservablePacketTransport implements AudioPacketTransport {
  Future<PacketTransportTermination> get done;
}

class AudioPacketByteTransport implements AudioObservablePacketTransport {
  AudioPacketByteTransport({
    required void Function(Uint8List bytes) sendBytes,
    Future<void> Function()? closeSink,
    AudioShareDiagnostics? diagnostics,
  }) : this.withTransport(
         PacketByteTransport(
           sendBytes: (bytes) => sendBytes(bytes as Uint8List),
           closeSink: closeSink ?? () async {},
         ),
         diagnostics: diagnostics,
       );

  AudioPacketByteTransport.withTransport(
    this._inner, {
    AudioShareDiagnostics? diagnostics,
  }) : _diagnostics = diagnostics ?? AudioShareDiagnostics.shared;

  final AudioShareDiagnostics _diagnostics;
  final PacketByteTransport _inner;

  @override
  Future<PacketTransportTermination> get done => _inner.done;

  void _emitSent(AudioPacketFrame packet) {
    _diagnostics.audioPacketSent(
      sessionId: packet.sessionId,
      sequence: packet.sequence,
      payloadBytes: packet.payload.length,
    );
  }

  void _emitDropped(AudioPacketFrame packet, {required String reason}) {
    _diagnostics.audioPacketSendDropped(
      sessionId: packet.sessionId,
      sequence: packet.sequence,
      reason: reason,
    );
  }

  @override
  void send(AudioPacketFrame packet) {
    if (_inner.isClosed) {
      _emitDropped(packet, reason: 'closed');
      return;
    }
    final delivery = _inner.send(packet.encode());
    unawaited(
      delivery.then((result) {
        if (result == PacketSendResult.sent) {
          _emitSent(packet);
        } else {
          final reason = switch (result) {
            PacketSendResult.sent => 'sent',
            PacketSendResult.dropped => 'backpressure',
            PacketSendResult.closed => 'closed',
            PacketSendResult.transportFailure => 'transport',
          };
          _emitDropped(packet, reason: reason);
        }
      }),
    );
  }

  @override
  Future<void> close() => _inner.close();
}

class AudioWebSocketPacketTransport extends AudioPacketByteTransport {
  AudioWebSocketPacketTransport._(
    PacketByteTransport channelTransport, {
    required AudioShareDiagnostics diagnostics,
  }) : super.withTransport(channelTransport, diagnostics: diagnostics);

  static Future<AudioWebSocketPacketTransport> connect(
    Uri uri, {
    required Uint8List mediaMacKey,
    required String sessionId,
    required String peerId,
    AudioShareDiagnostics? diagnostics,
  }) async {
    final resolvedDiagnostics = diagnostics ?? AudioShareDiagnostics.shared;
    resolvedDiagnostics.transportConnecting(uri);
    try {
      final channelTransport = await connectPacketWebSocket(
        uri,
        mediaUpgradeContext: MediaUpgradeClientContext(
          namespace: 'audio',
          sessionId: sessionId,
          peerId: peerId,
          mediaMacKey: mediaMacKey,
        ),
        packetEncoder: AuthenticatedMediaPacketEncoder(
          route: '/audio',
          namespace: 'audio',
          sessionId: sessionId,
          mediaMacKey: mediaMacKey,
          channelBinding: mediaPacketChannelBindingFromUri(uri),
          maxPayloadBytes: 256 * 1024,
        ),
      );
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
