import 'dart:async';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_web_socket/shelf_web_socket.dart' as shelf_ws;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/bounded_binary_websocket_session.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';

typedef RemoteInputPacketCallback = FutureOr<void> Function(
  RemoteInputPacketFrame packet,
);

enum RemoteInputSessionState {
  offering,
  connected,
  stopped,
  failed,
}

class RemoteInputSession {
  const RemoteInputSession({
    required this.sessionId,
    required this.sourcePeerId,
    required this.sinkPeerId,
    required this.layoutEdge,
    required this.releaseHotkey,
    required this.state,
  });

  final String sessionId;
  final String sourcePeerId;
  final String sinkPeerId;
  final RemoteInputEdge? layoutEdge;
  final String releaseHotkey;
  final RemoteInputSessionState state;

  RemoteInputSession copyWith({
    RemoteInputSessionState? state,
  }) {
    return RemoteInputSession(
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      layoutEdge: layoutEdge,
      releaseHotkey: releaseHotkey,
      state: state ?? this.state,
    );
  }
}

class RemoteInputManager {
  static const int maxPacketPayloadBytes = 64 * 1024;
  static const int maxChannelMessageBytes =
      maxPacketPayloadBytes + AuthenticatedMediaPacketEnvelope.overheadBytes;

  RemoteInputManager({
    this.onPacket,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  static final RemoteInputManager shared = RemoteInputManager();

  RemoteInputPacketCallback? onPacket;
  final Uuid _uuid;
  final Map<String, RemoteInputSession> _sessions =
      <String, RemoteInputSession>{};
  final Map<BoundedBinaryWebSocketSession, SessionUpgradeClaim> _channels =
      <BoundedBinaryWebSocketSession, SessionUpgradeClaim>{};
  final Map<BoundedBinaryWebSocketSession, Future<void>> _channelCloses =
      <BoundedBinaryWebSocketSession, Future<void>>{};
  Future<void>? _closeChannelsFuture;
  bool _closingChannels = false;
  Object? _channelCloseError;
  StackTrace? _channelCloseStackTrace;

  RemoteInputSession? session(String sessionId) => _sessions[sessionId];
  int get activeChannelCount => _channels.length;
  bool get hasActiveChannels => _channels.isNotEmpty;
  bool get isClosingChannels => _closingChannels;

  RemoteInputControlMessage createOffer({
    required String sourcePeerId,
    required String sinkPeerId,
    required RemoteInputEdge layoutEdge,
    required String releaseHotkey,
    String sourcePlatform = '',
    String sinkPlatform = '',
    String sourceDisplayId = '',
    RemoteInputEdge? sourceEdge,
    int sourceSegmentStart = 0,
    int sourceSegmentEnd = 0,
    String sinkDisplayId = '',
    RemoteInputEdge? sinkEdge,
    int sinkSegmentStart = 0,
    int sinkSegmentEnd = 0,
    List<RemoteInputEdgeMapping> edgeMappings =
        const <RemoteInputEdgeMapping>[],
  }) {
    final sessionId = _uuid.v4();
    _sessions[sessionId] = RemoteInputSession(
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      layoutEdge: layoutEdge,
      releaseHotkey: releaseHotkey,
      state: RemoteInputSessionState.offering,
    );
    return RemoteInputControlMessage(
      action: RemoteInputControlAction.offer,
      sessionId: sessionId,
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      layoutEdge: layoutEdge,
      releaseHotkey: releaseHotkey,
      transport: RemoteInputTransport.websocket,
      path: '/input',
      sourcePlatform: sourcePlatform,
      sinkPlatform: sinkPlatform,
      sourceDisplayId: sourceDisplayId,
      sourceEdge: sourceEdge,
      sourceSegmentStart: sourceSegmentStart,
      sourceSegmentEnd: sourceSegmentEnd,
      sinkDisplayId: sinkDisplayId,
      sinkEdge: sinkEdge,
      sinkSegmentStart: sinkSegmentStart,
      sinkSegmentEnd: sinkSegmentEnd,
      edgeMappings: edgeMappings,
    );
  }

  RemoteInputControlMessage acceptOffer(
    RemoteInputControlMessage offer, {
    String sinkPlatform = '',
  }) {
    if (offer.layoutEdge == null) {
      return RemoteInputControlMessage(
        action: RemoteInputControlAction.error,
        sessionId: offer.sessionId,
        sourcePeerId: offer.sourcePeerId,
        sinkPeerId: offer.sinkPeerId,
        errorMessage: 'remote input offer missing layout edge',
      );
    }
    _sessions[offer.sessionId] = RemoteInputSession(
      sessionId: offer.sessionId,
      sourcePeerId: offer.sourcePeerId,
      sinkPeerId: offer.sinkPeerId,
      layoutEdge: offer.layoutEdge,
      releaseHotkey: offer.releaseHotkey,
      state: RemoteInputSessionState.connected,
    );
    return RemoteInputControlMessage(
      action: RemoteInputControlAction.accept,
      sessionId: offer.sessionId,
      sourcePeerId: offer.sourcePeerId,
      sinkPeerId: offer.sinkPeerId,
      transport: offer.transport,
      path: offer.path,
      layoutEdge: offer.layoutEdge,
      sourceDisplayId: offer.sourceDisplayId,
      sourceEdge: offer.sourceEdge,
      sourceSegmentStart: offer.sourceSegmentStart,
      sourceSegmentEnd: offer.sourceSegmentEnd,
      sinkDisplayId: offer.sinkDisplayId,
      sinkEdge: offer.sinkEdge,
      sinkSegmentStart: offer.sinkSegmentStart,
      sinkSegmentEnd: offer.sinkSegmentEnd,
      edgeMappings: offer.edgeMappings,
      releaseHotkey: offer.releaseHotkey,
      sourcePlatform: offer.sourcePlatform,
      sinkPlatform: sinkPlatform.isNotEmpty ? sinkPlatform : offer.sinkPlatform,
    );
  }

  void handleControlMessage(RemoteInputControlMessage message) {
    switch (message.action) {
      case RemoteInputControlAction.offer:
        if (message.layoutEdge != null) {
          _sessions[message.sessionId] = RemoteInputSession(
            sessionId: message.sessionId,
            sourcePeerId: message.sourcePeerId,
            sinkPeerId: message.sinkPeerId,
            layoutEdge: message.layoutEdge,
            releaseHotkey: message.releaseHotkey,
            state: RemoteInputSessionState.offering,
          );
        }
        break;
      case RemoteInputControlAction.accept:
        final current = _sessions[message.sessionId];
        final layoutEdge = message.layoutEdge ?? current?.layoutEdge;
        _sessions[message.sessionId] = RemoteInputSession(
          sessionId: message.sessionId,
          sourcePeerId: message.sourcePeerId,
          sinkPeerId: message.sinkPeerId,
          layoutEdge: layoutEdge,
          releaseHotkey: message.releaseHotkey.isNotEmpty
              ? message.releaseHotkey
              : current?.releaseHotkey ?? '',
          state: RemoteInputSessionState.connected,
        );
        break;
      case RemoteInputControlAction.release:
        break;
      case RemoteInputControlAction.stop:
      case RemoteInputControlAction.reject:
        stopSession(message.sessionId);
        break;
      case RemoteInputControlAction.error:
        final current = _sessions[message.sessionId];
        if (current != null) {
          _sessions[message.sessionId] = current.copyWith(
            state: RemoteInputSessionState.failed,
          );
        }
        break;
    }
  }

  void stopSession(String sessionId) {
    final current = _sessions[sessionId];
    if (current != null) {
      _sessions[sessionId] = current.copyWith(
        state: RemoteInputSessionState.stopped,
      );
    }
    unawaited(
      closeSessionChannels(
        sessionId,
        peerId: current?.sourcePeerId,
        namespace: 'remote-input',
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

  FutureOr<void> handlePacketBytes(
    Uint8List bytes, {
    String? expectedSessionId,
  }) {
    final packet = RemoteInputPacketFrame.decode(bytes);
    if (expectedSessionId != null && packet.sessionId != expectedSessionId) {
      throw const FormatException('remote input packet session mismatch');
    }
    final activeSession = _sessions[packet.sessionId];
    if (activeSession?.state != RemoteInputSessionState.connected) {
      return Future<void>.value();
    }
    final callback = onPacket;
    if (callback == null) {
      return Future<void>.value();
    }
    return callback(packet);
  }

  bool canAttachClaim(
    SessionUpgradeClaim claim, {
    bool Function(SessionUpgradeClaim claim)? claimValidator,
  }) {
    if (claim.route != '/input' ||
        claim.namespace != 'remote-input' ||
        claimValidator?.call(claim) == false ||
        _channels.values.any(
          (active) =>
              active.route == claim.route &&
              active.namespace == claim.namespace &&
              active.sessionId == claim.sessionId &&
              active.peerId == claim.peerId,
        )) {
      return false;
    }
    final session = _sessions[claim.sessionId];
    return session?.state == RemoteInputSessionState.connected &&
        session?.sourcePeerId == claim.peerId;
  }

  bool attachChannel(
    WebSocketChannel channel, {
    required SessionUpgradeClaim claim,
    bool Function(SessionUpgradeClaim claim)? claimValidator,
  }) {
    if (!canAttachClaim(claim, claimValidator: claimValidator)) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return false;
    }
    final packetDecoder = AuthenticatedMediaPacketDecoder(
      route: claim.route,
      sessionId: claim.sessionId,
      mediaMacKey: claim.mediaMacKey,
      maxPayloadBytes: maxPacketPayloadBytes,
    );
    late final BoundedBinaryWebSocketSession binding;
    binding = BoundedBinaryWebSocketSession(
      channel: channel,
      maxMessageBytes: maxChannelMessageBytes,
      onMessage: (bytes) => handlePacketBytes(
        packetDecoder.decode(bytes),
        expectedSessionId: claim.sessionId,
      ),
      onClosed: () => _channels.remove(binding),
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
