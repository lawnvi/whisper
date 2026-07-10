import 'dart:async';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_web_socket/shelf_web_socket.dart' as shelf_ws;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_diagnostics.dart';
import 'package:whisper/socket/bounded_binary_websocket_session.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

typedef AudioPacketCallback = void Function(AudioPacketFrame packet);
typedef AudioGroupPacketCallback = void Function(AudioGroupPacketFrame packet);
typedef AudioGroupPacketClaimValidator = bool Function(
  SessionUpgradeClaim claim,
  AudioGroupPacketFrame packet,
);

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
  static const int maxPacketPayloadBytes = 256 * 1024;
  static const int maxChannelMessageBytes =
      maxPacketPayloadBytes + AuthenticatedMediaPacketEnvelope.overheadBytes;

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
  final Map<BoundedBinaryWebSocketSession, SessionUpgradeClaim> _channels =
      <BoundedBinaryWebSocketSession, SessionUpgradeClaim>{};
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
    unawaited(
      closeSessionChannels(
        sessionId,
        peerId: current?.sourcePeerId,
        namespace: 'audio',
      ),
    );
  }

  Future<void> closeSessionChannels(
    String sessionId, {
    String? peerId,
    String? namespace,
  }) {
    return _closeMatchingChannels(
      (claim) =>
          claim.sessionId == sessionId &&
          (peerId == null || claim.peerId == peerId) &&
          (namespace == null || claim.namespace == namespace),
    );
  }

  Future<void> closePeerChannels(String peerId) {
    return _closeMatchingChannels((claim) => claim.peerId == peerId);
  }

  Future<void> closeSupersededPeerChannels(
    String peerId, {
    required Uint8List mediaMacKey,
  }) {
    return _closeMatchingChannels(
      (claim) =>
          claim.peerId == peerId &&
          !constantTimeBytesEqual(claim.mediaMacKey, mediaMacKey),
    );
  }

  Future<void> _closeMatchingChannels(
    bool Function(SessionUpgradeClaim claim) matches,
  ) async {
    final channels = _channels.entries
        .where((entry) => matches(entry.value))
        .map((entry) => entry.key)
        .toList(growable: false);
    await Future.wait(channels.map(_trackChannelClose));
  }

  void handlePacketBytes(Uint8List bytes) {
    try {
      final packet = AudioPacketFrame.decode(bytes);
      _deliverAudioPacket(packet);
      return;
    } on FormatException catch (legacyError) {
      try {
        final packet = AudioGroupPacketFrame.decode(bytes);
        _deliverGroupPacket(packet);
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

  void _deliverAudioPacket(AudioPacketFrame packet) {
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
  }

  void _deliverGroupPacket(AudioGroupPacketFrame packet) {
    _diagnostics.groupPacketDelivered(
      groupId: packet.groupId,
      streamId: packet.streamId,
      sequence: packet.sequence,
      payloadBytes: packet.payload.length,
    );
    onGroupPacket?.call(packet);
  }

  void _handleClaimPacketBytes(
    Uint8List bytes, {
    required SessionUpgradeClaim claim,
    required bool isDirectAudio,
    AudioGroupPacketClaimValidator? groupPacketValidator,
  }) {
    if (isDirectAudio) {
      final packet = AudioPacketFrame.decode(bytes);
      if (packet.sessionId != claim.sessionId) {
        throw const FormatException('audio packet session mismatch');
      }
      _deliverAudioPacket(packet);
      return;
    }
    final packet = AudioGroupPacketFrame.decode(bytes);
    if (packet.sessionId != claim.sessionId ||
        packet.sourcePeerId != claim.peerId ||
        groupPacketValidator?.call(claim, packet) != true) {
      throw const FormatException('audio group packet claim mismatch');
    }
    _deliverGroupPacket(packet);
  }

  bool _isDirectAudioClaim(SessionUpgradeClaim claim) {
    final session = _sessions[claim.sessionId];
    return session?.state == AudioShareSessionState.connected &&
        session?.sourcePeerId == claim.peerId;
  }

  bool _hasActiveClaimChannel(SessionUpgradeClaim claim) {
    return _channels.values.any(
      (active) =>
          active.route == claim.route &&
          active.namespace == claim.namespace &&
          active.sessionId == claim.sessionId &&
          active.peerId == claim.peerId,
    );
  }

  bool canAttachClaim(
    SessionUpgradeClaim claim, {
    bool Function(SessionUpgradeClaim claim)? additionalValidator,
    bool Function(SessionUpgradeClaim claim)? claimValidator,
  }) {
    if (claim.route != '/audio' ||
        claimValidator?.call(claim) == false ||
        _hasActiveClaimChannel(claim)) {
      return false;
    }
    return switch (claim.namespace) {
      'audio' => _isDirectAudioClaim(claim),
      'audio-group' => additionalValidator?.call(claim) ?? false,
      _ => false,
    };
  }

  bool attachChannel(
    WebSocketChannel channel, {
    required SessionUpgradeClaim claim,
    bool Function(SessionUpgradeClaim claim)? additionalValidator,
    AudioGroupPacketClaimValidator? groupPacketValidator,
    bool Function(SessionUpgradeClaim claim)? claimValidator,
  }) {
    final isDirectAudio = claim.namespace == 'audio';
    final hasExpectedControl = switch (claim.namespace) {
      'audio' => _isDirectAudioClaim(claim),
      'audio-group' => additionalValidator?.call(claim) ?? false,
      _ => false,
    };
    if (claim.route != '/audio' ||
        claimValidator?.call(claim) == false ||
        (_hasActiveClaimChannel(claim) && !_closingChannels) ||
        !hasExpectedControl) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    final packetDecoder = AuthenticatedMediaPacketDecoder(
      route: claim.route,
      sessionId: claim.sessionId,
      mediaMacKey: claim.mediaMacKey,
      maxPayloadBytes: maxPacketPayloadBytes,
    );
    _diagnostics.audioChannelAttached();
    late final BoundedBinaryWebSocketSession binding;
    binding = BoundedBinaryWebSocketSession(
      channel: channel,
      maxMessageBytes: maxChannelMessageBytes,
      onMessage: (bytes) {
        _diagnostics.audioChannelMessageBytes(bytes.length);
        _handleClaimPacketBytes(
          packetDecoder.decode(bytes),
          claim: claim,
          isDirectAudio: isDirectAudio,
          groupPacketValidator: groupPacketValidator,
        );
      },
      onError: _diagnostics.audioChannelError,
      onClosed: () {
        _channels.remove(binding);
        _diagnostics.audioChannelClosed();
      },
    );
    _channels[binding] = claim;
    if (_closingChannels) {
      unawaited(_trackChannelClose(binding));
    }
    return true;
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
          for (final channel in _channels.keys.toList(growable: false)) {
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
    required SessionUpgradeClaim claim,
    bool Function(SessionUpgradeClaim claim)? additionalValidator,
    AudioGroupPacketClaimValidator? groupPacketValidator,
    bool Function(SessionUpgradeClaim claim)? claimValidator,
    Duration pingInterval = const Duration(seconds: 15),
    void Function()? onAttachmentComplete,
  }) {
    return shelf_ws.webSocketHandler(
      (WebSocketChannel channel) {
        try {
          attachChannel(
            channel,
            claim: claim,
            additionalValidator: additionalValidator,
            groupPacketValidator: groupPacketValidator,
            claimValidator: claimValidator,
          );
        } finally {
          onAttachmentComplete?.call();
        }
      },
      pingInterval: pingInterval,
    );
  }
}
