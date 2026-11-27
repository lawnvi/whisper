import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/state/peer_reconnect_controller.dart';

abstract class ISocketEvent {
  void onError(String message);

  void onNotice(String message);

  void onMessage(MessageData messageData);

  void onTransferUpdated(TransferSnapshot snapshot);

  void onClose();

  void onConnect();

  void onPairing(PairingRequest request, void Function(bool) resolve);

  void afterAuth(bool allow, DeviceData? device);
}

typedef PeerReconnectControllerFactory =
    PeerReconnectController Function({
      required ReconnectAttempt attempt,
      required ReconnectEligibility eligibility,
    });

typedef LocalPeerProfileLoader = Future<PeerProfile> Function();

enum ConnectionAuthCommitStage {
  beforePersistence,
  afterPersistence,
  beforeRegistration,
  afterRegistration,
}

typedef ConnectionAuthCommitBarrier =
    Future<void> Function(ConnectionAuthCommitStage stage, String peerId);

typedef AuthEnvelopeObserver =
    void Function(PeerSocketRole role, AuthEnvelope envelope);

enum PeerDisconnectCause {
  network,
  watchdog,
  manual,
  trustRevoked,
  deviceDeleted,
  superseded,
  protocolFailure,
  localFailure,
  managerClose,
  systemSleep,
}

final class ServerStartResult {
  const ServerStartResult.success(this.port) : isSuccess = true, error = null;

  const ServerStartResult.failure(this.error) : isSuccess = false, port = 0;

  final bool isSuccess;
  final int port;
  final Object? error;
}
