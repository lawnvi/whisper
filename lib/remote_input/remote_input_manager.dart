import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_web_socket/shelf_web_socket.dart' as shelf_ws;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

typedef RemoteInputPacketCallback = void Function(
    RemoteInputPacketFrame packet);

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
  RemoteInputManager({
    this.onPacket,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  static final RemoteInputManager shared = RemoteInputManager();

  RemoteInputPacketCallback? onPacket;
  final Uuid _uuid;
  final Map<String, RemoteInputSession> _sessions =
      <String, RemoteInputSession>{};

  RemoteInputSession? session(String sessionId) => _sessions[sessionId];

  RemoteInputControlMessage createOffer({
    required String sourcePeerId,
    required String sinkPeerId,
    required RemoteInputEdge layoutEdge,
    required String releaseHotkey,
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
    );
  }

  RemoteInputControlMessage acceptOffer(RemoteInputControlMessage offer) {
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
      releaseHotkey: offer.releaseHotkey,
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
  }

  void handlePacketBytes(Uint8List bytes) {
    final packet = RemoteInputPacketFrame.decode(bytes);
    final activeSession = _sessions[packet.sessionId];
    if (activeSession?.state != RemoteInputSessionState.connected) {
      return;
    }
    onPacket?.call(packet);
  }

  void attachChannel(WebSocketChannel channel) {
    channel.stream.listen((message) {
      final bytes = _messageBytes(message);
      if (bytes != null) {
        handlePacketBytes(bytes);
      }
    });
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
