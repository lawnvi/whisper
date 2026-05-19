import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_web_socket/shelf_web_socket.dart' as shelf_ws;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';

typedef AudioPacketCallback = void Function(AudioPacketFrame packet);
typedef AudioGroupPacketCallback = void Function(AudioGroupPacketFrame packet);

enum AudioShareSessionState {
  offering,
  connected,
  stopped,
  failed,
}

class AudioShareSession {
  const AudioShareSession({
    required this.sessionId,
    required this.sourcePeerId,
    required this.sinkPeerId,
    required this.format,
    required this.state,
  });

  final String sessionId;
  final String sourcePeerId;
  final String sinkPeerId;
  final AudioStreamFormat format;
  final AudioShareSessionState state;

  AudioShareSession copyWith({
    AudioShareSessionState? state,
  }) {
    return AudioShareSession(
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      format: format,
      state: state ?? this.state,
    );
  }
}

class AudioShareManager {
  AudioShareManager({
    this.onPacket,
    this.onGroupPacket,
    Uuid? uuid,
    AudioShareDiagnostics? diagnostics,
  })  : _uuid = uuid ?? const Uuid(),
        _diagnostics = diagnostics ?? AudioShareDiagnostics.shared;

  static final AudioShareManager shared = AudioShareManager();

  AudioPacketCallback? onPacket;
  AudioGroupPacketCallback? onGroupPacket;
  final Uuid _uuid;
  final AudioShareDiagnostics _diagnostics;
  final Map<String, AudioShareSession> _sessions =
      <String, AudioShareSession>{};

  AudioShareSession? session(String sessionId) => _sessions[sessionId];

  AudioControlMessage createOffer({
    required String sourcePeerId,
    required String sinkPeerId,
    required AudioStreamFormat format,
  }) {
    final sessionId = _uuid.v4();
    _sessions[sessionId] = AudioShareSession(
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      format: format,
      state: AudioShareSessionState.offering,
    );
    return AudioControlMessage(
      action: AudioControlAction.offer,
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      format: format,
      transport: AudioTransport.websocket,
      path: '/audio',
    );
  }

  AudioControlMessage acceptOffer(AudioControlMessage offer) {
    final format = offer.format;
    if (format == null) {
      return AudioControlMessage(
        action: AudioControlAction.error,
        sessionId: offer.sessionId,
        sourcePeerId: offer.sourcePeerId,
        sinkPeerId: offer.sinkPeerId,
        errorMessage: 'audio offer missing format',
      );
    }
    _sessions[offer.sessionId] = AudioShareSession(
      sessionId: offer.sessionId,
      sourcePeerId: offer.sourcePeerId,
      sinkPeerId: offer.sinkPeerId,
      format: format,
      state: AudioShareSessionState.connected,
    );
    return AudioControlMessage(
      action: AudioControlAction.accept,
      sessionId: offer.sessionId,
      sourcePeerId: offer.sourcePeerId,
      sinkPeerId: offer.sinkPeerId,
      format: format,
      transport: offer.transport,
      path: offer.path,
    );
  }

  void handleControlMessage(AudioControlMessage message) {
    switch (message.action) {
      case AudioControlAction.offer:
        final format = message.format;
        if (format != null) {
          _sessions[message.sessionId] = AudioShareSession(
            sessionId: message.sessionId,
            sourcePeerId: message.sourcePeerId,
            sinkPeerId: message.sinkPeerId,
            format: format,
            state: AudioShareSessionState.offering,
          );
        }
        break;
      case AudioControlAction.accept:
        final current = _sessions[message.sessionId];
        final format = message.format ?? current?.format;
        if (format != null) {
          _sessions[message.sessionId] = AudioShareSession(
            sessionId: message.sessionId,
            sourcePeerId: message.sourcePeerId,
            sinkPeerId: message.sinkPeerId,
            format: format,
            state: AudioShareSessionState.connected,
          );
        }
        break;
      case AudioControlAction.stop:
      case AudioControlAction.reject:
        stopSession(message.sessionId);
        break;
      case AudioControlAction.error:
        final current = _sessions[message.sessionId];
        if (current != null) {
          _sessions[message.sessionId] = current.copyWith(
            state: AudioShareSessionState.failed,
          );
        }
        break;
    }
  }

  void stopSession(String sessionId) {
    final current = _sessions[sessionId];
    if (current != null) {
      _sessions[sessionId] = current.copyWith(
        state: AudioShareSessionState.stopped,
      );
    }
  }

  void handlePacketBytes(Uint8List bytes) {
    try {
      final packet = AudioPacketFrame.decode(bytes);
      final activeSession = _sessions[packet.sessionId];
      if (activeSession?.state != AudioShareSessionState.connected) {
        _diagnostics.audioPacketDropped(
          sessionId: packet.sessionId,
          sequence: packet.sequence,
          payloadBytes: packet.payload.length,
          state: activeSession?.state.name ?? 'missing',
        );
        return;
      }
      _diagnostics.audioPacketDelivered(
        sessionId: packet.sessionId,
        sequence: packet.sequence,
        payloadBytes: packet.payload.length,
      );
      onPacket?.call(packet);
      return;
    } on FormatException catch (legacyError) {
      try {
        final packet = AudioGroupPacketFrame.decode(bytes);
        _diagnostics.groupPacketDelivered(
          groupId: packet.groupId,
          streamId: packet.streamId,
          sequence: packet.sequence,
          payloadBytes: packet.payload.length,
        );
        onGroupPacket?.call(packet);
        return;
      } on FormatException catch (groupError) {
        _diagnostics.packetDecodeFailed(
          bytes: bytes.length,
          legacyError: legacyError,
          groupError: groupError,
        );
        throw legacyError;
      }
    }
  }

  void attachChannel(WebSocketChannel channel) {
    _diagnostics.audioChannelAttached();
    channel.stream.listen((message) {
      final bytes = _messageBytes(message);
      if (bytes != null) {
        _diagnostics.audioChannelMessageBytes(bytes.length);
        handlePacketBytes(bytes);
      }
    },
        onError: _diagnostics.audioChannelError,
        onDone: _diagnostics.audioChannelClosed);
  }

  shelf.Handler webSocketHandler({
    Duration pingInterval = const Duration(seconds: 15),
  }) {
    return shelf_ws.webSocketHandler(
      (WebSocketChannel channel) {
        attachChannel(channel);
      },
      pingInterval: pingInterval,
    );
  }

  Uint8List? _messageBytes(dynamic message) {
    if (message is Uint8List) {
      return message;
    }
    if (message is List<int>) {
      return Uint8List.fromList(message);
    }
    if (message is String) {
      return Uint8List.fromList(utf8.encode(message));
    }
    return null;
  }
}
