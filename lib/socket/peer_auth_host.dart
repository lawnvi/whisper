import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/debug/automation_hooks.dart' show DebugPairingRequests;
import 'package:whisper/helper/connection_request_notifications.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/auth_handshake_lifecycle.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/outgoing_text_retry.dart';
import 'package:whisper/socket/peer_directory.dart';
import 'package:whisper/socket/peer_policy_store.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/pending_outgoing_connection.dart';
import 'package:whisper/socket/socket_events.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_profile.dart';

final class SocketAuthResult {
  const SocketAuthResult(this.allow, this.message);

  final bool allow;
  final String message;
}

typedef IdentityPinPlan = ({PairingReason? reason, String expectedPublicKey});

abstract interface class PeerAuthHost {
  PeerDirectory get peers;
  PeerPolicyStore get policy;
  LocalDatabase get database;
  FileTransferEngine get transferEngine;
  OutgoingTextRetryRegistry get outgoingTextRetries;
  bool get manageSharedCoordinators;
  int get nextConnectionGeneration;
  AuthEnvelopeObserver? get authEnvelopeObserver;
  ConnectionAuthCommitBarrier? get authCommitBarrier;
  Future<bool> Function() get autoConnectEnabled;
  bool? get autoConnectPolicyOverride;
  ISocketEvent? get primaryEvent;

  PendingOutgoingConnection? pendingOutgoingForSink(WebSocketSink sink);
  void bindPendingOutgoingPeer(
    PendingOutgoingConnection attempt,
    String peerId,
  );
  bool hasReadyPendingOutgoingForPeer(String peerId);
  bool hasPendingOutgoingForPeer(String peerId);
  void cancelLosingOutgoingForPeer(String peerId);
  void recordAuthenticatedReconnect(
    PeerSocketSession session,
    WebSocketSink sink,
    DeviceData device,
  );
  Future<bool> registerPeerConnection({
    required String peerId,
    required WebSocketSink sink,
    required PeerSocketSession session,
    PeerProfile? profile,
  });
  Future<void> closeSupersededMediaChannels(PeerSocketSession session);
  Future<void> failSocketSession(
    PeerSocketSession session,
    WebSocketSink sink,
    String message, {
    PeerDisconnectCause cause = PeerDisconnectCause.protocolFailure,
  });
  MessageData buildAuthMessage({
    required String content,
    required String msg,
    String? senderOverride,
    String? receiverOverride,
  });
  Future<bool> sendRawAuthMessage(
    MessageData message, {
    required WebSocketSink sink,
  });
  void startKeepaliveTimer(String peerId, WebSocketSink sink);
  void dispatchConnect();
  void dispatchAfterAuth(bool allow, DeviceData? device);
  void dispatchPairing(
    ISocketEvent listener,
    PairingRequest request,
    void Function(bool) resolve,
  );
  Future<bool> sendRemoteInputControlTo(
    String peerId,
    RemoteInputControlMessage control,
  );
  void ignoreFuture(Future<void> future, {required String context});
}

Future<void> sendAuthUpgradeRequired(
  PeerAuthHost host,
  WebSocketSink sink,
  PeerSocketSession session, {
  String action = 'upgrade_required',
}) async {
  final payload = jsonEncode(<String, Object?>{
    'action': action,
    'version': PeerSocketSession.protocolVersion,
    'minVersion': PeerSocketSession.minimumProtocolVersion,
    'maxVersion': PeerSocketSession.protocolVersion,
  });
  final message = host.buildAuthMessage(
    content: payload,
    msg: action,
    senderOverride: session.localProfile.uid,
    receiverOverride: session.remotePeerId,
  );
  await host.sendRawAuthMessage(message, sink: sink);
}

Future<void> presentAuthPairingDecision({
  required PeerAuthHost host,
  required PeerSocketSession session,
  required WebSocketSink sink,
  required DeviceData device,
  required PairingReason reason,
  required PairingPromptMode mode,
  required bool Function(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  )
  isSameSession,
  required Future<void> Function(bool) resolve,
}) async {
  final listener = host.primaryEvent;
  if (listener == null) {
    await resolve(false);
    return;
  }
  final generation = session.connectionGeneration;
  final sessionGuarded = session.guardApprovalCallback((allow) {
    final handling = AuthHandshakeLifecycle.resolveGuarded(
      resolve: () => resolve(allow),
      onFailure: (error, stackTrace) async {
        logger.i('处理配对决定失败: $error\n$stackTrace');
        if (isSameSession(session, sink, generation)) {
          await host.failSocketSession(
            session,
            sink,
            error is AuthHandshakeException
                ? error.code
                : 'authentication_failed',
            cause: error is AuthHandshakeException
                ? PeerDisconnectCause.protocolFailure
                : PeerDisconnectCause.localFailure,
          );
        }
      },
    );
    host.ignoreFuture(
      handling.then<void>((_) {}),
      context: 'handle guarded pairing decision',
    );
  });
  final presentation = PairingPresentationBinding(
    sessionCancellation: session.pairingResolved,
    onResolve: sessionGuarded,
  );
  final request = PairingRequest(
    device: device,
    pairingCode: session.pairingCode,
    reason: reason,
    mode: mode,
    cancellation: presentation.cancellation,
    presentation: presentation,
  );
  if (kDebugMode) {
    // Test machines are paired by the automation hooks, not by a click.
    DebugPairingRequests.add(request);
  }
  host.ignoreFuture(
    ConnectionRequestNotifier().maybeShowForPairing(
      request: request,
      resolve: presentation.resolve,
    ),
    context: 'show pairing notification',
  );
  host.dispatchPairing(listener, request, presentation.resolve);
}
