import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/authenticated_frame.dart';
import 'package:whisper/socket/media_dial_back.dart';
import 'package:whisper/socket/outbound_frame_class.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/socket_events.dart';

/// Per-socket state for a single `/chat` WebSocket link from transport attach
/// through authentication, active messaging, and teardown.
class PeerLink {
  PeerLink({required this.sink, this.endpoint, this.session});

  final WebSocketSink sink;
  ({String host, int port})? endpoint;
  PeerSocketSession? session;

  /// Set once this link is registered as the active connection for a peer.
  String? registeredPeerId;

  /// Terminal disconnect cause recorded when closing due to a known reason.
  PeerDisconnectCause? terminalDisconnectCause;

  /// Highest connection generation observed when this link's session committed
  /// authentication; used to detect simultaneous opposite-direction handshakes.
  int? authCommitWatermark;

  /// True if registering this link superseded an earlier active connection.
  bool supersededOnAuth = false;

  /// When true, closing this link during supersede defers the underlying TCP
  /// close until the replacement link sends its `result(allow: true)`.
  bool deferCloseForSuperseded = false;

  /// Previous link's sink whose TCP close was deferred until this link
  /// finishes announcing its authenticated session.
  WebSocketSink? deferredSupersededSink;

  int get generation => session?.connectionGeneration ?? 0;

  bool get isAuthenticated => session?.isAuthenticated == true;

  String get remotePeerId => session?.remotePeerId ?? '';

  String get localPeerId => session?.localProfile.uid ?? '';

  String? get plainHost {
    final host = endpoint?.host;
    if (host == null || host.isEmpty) {
      return null;
    }
    return plainPeerHost(host);
  }

  PeerDisconnectCause takeTerminalDisconnectCause() {
    final cause = terminalDisconnectCause;
    terminalDisconnectCause = null;
    return cause ?? PeerDisconnectCause.network;
  }

  bool takeSupersededOnAuth() {
    final value = supersededOnAuth;
    supersededOnAuth = false;
    return value;
  }

  bool takeDeferCloseForSuperseded() {
    final value = deferCloseForSuperseded;
    deferCloseForSuperseded = false;
    return value;
  }

  WebSocketSink? takeDeferredSupersededSink() {
    final deferred = deferredSupersededSink;
    deferredSupersededSink = null;
    return deferred;
  }

  Future<bool> sendBytes(
    Object message, {
    bool rawAuth = false,
    required int maxPreAuthBytes,
    required int maxAuthenticatedBytes,
    required int authenticatedFrameOverhead,
    required Future<void> Function() closeTransport,
  }) async {
    final activeSession = session;
    final buffered = message is AuthenticatedPayloadBuffer ? message : null;
    final bytes = buffered?.payload ?? outgoingPayloadBytes(message);
    if (activeSession == null || bytes == null) {
      await closeTransport();
      return false;
    }
    final maxBytes = rawAuth ? maxPreAuthBytes : maxAuthenticatedBytes;
    if (bytes.length > maxBytes) {
      activeSession.close();
      await closeTransport();
      return false;
    }
    if (rawAuth) {
      return buffered == null &&
          await activeSession.enqueueOutgoing(bytes, byteLength: bytes.length);
    }
    if (!activeSession.isAuthenticated) {
      await closeTransport();
      return false;
    }
    final byteLength = bytes.length + authenticatedFrameOverhead;
    final cls = classifyOutboundFrame(bytes);
    if (buffered != null) {
      return activeSession.enqueueAuthenticatedBuffer(
        buffered,
        byteLength: byteLength,
        kind: cls.kind,
        waitForSpace: cls.waitForSpace,
      );
    }
    return activeSession.enqueueAuthenticatedOutgoing(
      bytes,
      byteLength: byteLength,
      kind: cls.kind,
      waitForSpace: cls.waitForSpace,
    );
  }
}
