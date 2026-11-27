import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/socket/direct_peer_http_client.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/transport_close_guard.dart';
import 'package:whisper/state/connection_attempt.dart';

final class PendingOutgoingConnection {
  PendingOutgoingConnection(
    this.request, {
    required this.globalPolicyEpoch,
    required this.peerPolicyEpoch,
    required this.startedPolicyRevision,
    required this.socketCloseTimeout,
  }) : httpClient = newDirectPeerHttpClient();

  final ConnectionAttemptRequest request;
  final int globalPolicyEpoch;
  int peerPolicyEpoch;
  int startedPolicyRevision;
  final Duration socketCloseTimeout;
  final HttpClient httpClient;
  WebSocketChannel? channel;
  HttpClientRequest? transportRequest;
  PeerSocketSession? session;
  String verifiedPeerId = '';
  Future<ConnectionAttemptResult>? completion;
  TransportCloseGuard? _sinkCloseGuard;
  bool isCancelled = false;
  bool isReady = false;
  bool allowsDeviceRepair = false;
  bool allowsTrustRepair = false;
  ConnectionAttemptReason cancellationReason =
      ConnectionAttemptReason.requestCancelled;

  void resetTransportForProtocolRetry() {
    channel = null;
    transportRequest = null;
    session = null;
    isReady = false;
    _sinkCloseGuard = null;
  }

  Future<void> cancel({
    ConnectionAttemptReason reason = ConnectionAttemptReason.requestCancelled,
  }) {
    session?.close();
    if (!isCancelled) {
      cancellationReason = reason;
    }
    isCancelled = true;
    transportRequest?.abort(const OutgoingConnectionCancelled());
    httpClient.close(force: true);
    final sink = channel?.sink;
    if (sink != null) {
      _sinkCloseGuard ??= TransportCloseGuard(
        close: () async {
          await sink.close();
        },
        timeout: socketCloseTimeout,
      );
      unawaited(
        _sinkCloseGuard!.close().catchError((Object _, StackTrace __) {}),
      );
    }
    if (isReady && _sinkCloseGuard != null) {
      return _sinkCloseGuard!.close();
    }
    return Future<void>.value();
  }
}

final class OutgoingConnectionCancelled implements Exception {
  const OutgoingConnectionCancelled();
}

final class WebSocketUpgradeRejected implements Exception {
  const WebSocketUpgradeRejected(this.reason, this.statusCode);

  final String reason;
  final int statusCode;
}
