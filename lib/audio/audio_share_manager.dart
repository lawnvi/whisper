import 'dart:async';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_web_socket/shelf_web_socket.dart' as shelf_ws;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';
import 'package:whisper/socket/bounded_binary_websocket_session.dart';

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
  static const int maxChannelMessageBytes = 256 * 1024;

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
  final Set<BoundedBinaryWebSocketSession> _channels =
      <BoundedBinaryWebSocketSession>{};
  final Map<BoundedBinaryWebSocketSession, Future<void>> _channelCloses =
      <BoundedBinaryWebSocketSession, Future<void>>{};
  Future<void>? _closeChannelsFuture;
  bool _closingChannels = false;
  Object? _channelCloseError;
  StackTrace? _channelCloseStackTrace;

  AudioShareSession? session(String sessionId) => _sessions[sessionId];
  int get activeChannelCount => _channels.length;
  bool get hasActiveChannels => _channels.isNotEmpty;
  bool get isClosingChannels => _closingChannels;

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
    late final BoundedBinaryWebSocketSession binding;
    binding = BoundedBinaryWebSocketSession(
      channel: channel,
      maxMessageBytes: maxChannelMessageBytes,
      onMessage: (bytes) {
        _diagnostics.audioChannelMessageBytes(bytes.length);
        handlePacketBytes(bytes);
      },
      onError: _diagnostics.audioChannelError,
      onClosed: () {
        _channels.remove(binding);
        _diagnostics.audioChannelClosed();
      },
    );
    _channels.add(binding);
    if (_closingChannels) {
      unawaited(_trackChannelClose(binding));
    }
  }

  Future<void> _trackChannelClose(BoundedBinaryWebSocketSession channel) {
    final existing = _channelCloses[channel];
    if (existing != null) {
      return existing;
    }
    late final Future<void> tracked;
    tracked = channel.close().then<void>((_) {},
        onError: (Object error, StackTrace stackTrace) {
      _channelCloseError ??= error;
      _channelCloseStackTrace ??= stackTrace;
    }).whenComplete(() {
      if (identical(_channelCloses[channel], tracked)) {
        _channelCloses.remove(channel);
      }
    });
    _channelCloses[channel] = tracked;
    return tracked;
  }

  Future<void> closeChannels() {
    final existing = _closeChannelsFuture;
    if (existing != null) {
      return existing;
    }
    _closingChannels = true;
    final completer = Completer<void>();
    final closeFuture = completer.future;
    _closeChannelsFuture = closeFuture;
    _channelCloseError = null;
    _channelCloseStackTrace = null;
    unawaited(() async {
      try {
        while (_channels.isNotEmpty || _channelCloses.isNotEmpty) {
          for (final channel in _channels.toList(growable: false)) {
            _trackChannelClose(channel);
          }
          final closes = _channelCloses.values.toList(growable: false);
          if (closes.isNotEmpty) {
            await Future.wait(closes);
          }
        }
        if (_channelCloseError case final error?) {
          Error.throwWithStackTrace(error, _channelCloseStackTrace!);
        }
      } finally {
        _closingChannels = false;
        if (identical(_closeChannelsFuture, closeFuture)) {
          _closeChannelsFuture = null;
        }
      }
    }()
        .then<void>((_) {
      completer.complete();
    }, onError: (Object error, StackTrace stackTrace) {
      completer.completeError(error, stackTrace);
    }));
    return closeFuture;
  }

  shelf.Handler webSocketHandler({
    Duration pingInterval = const Duration(seconds: 15),
    void Function()? onAttachmentComplete,
  }) {
    return shelf_ws.webSocketHandler(
      (WebSocketChannel channel) {
        try {
          attachChannel(channel);
        } finally {
          onAttachmentComplete?.call();
        }
      },
      pingInterval: pingInterval,
    );
  }
}
