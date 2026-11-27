import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_files/fs_protocol.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/file_browse_trust_cache.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/outgoing_text_retry.dart';
import 'package:whisper/socket/peer_directory.dart';
import 'package:whisper/socket/peer_ping_tracker.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/socket/wire_message_replay.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';

abstract interface class ChannelRouterHost {
  PeerDirectory get peers;
  PeerPingTracker get pingTracker;
  FileTransferEngine get transferEngine;
  RemoteClipboardTransferEngine get remoteClipboardTransfer;
  WireMessageReplayGuard get wireMessageReplayGuard;
  WireControlSessionRegistry get wireControlSessions;
  OutgoingTextAcknowledgementTracker get outgoingTextAcknowledgements;
  FileBrowseTrustCache get fileBrowseTrustCache;
  LocalDatabase get database;
  bool get manageSharedCoordinators;
  int get maxFileDataPayloadBytes;
  String get fileBrowseNamespace;
  String get localSenderUid;

  void requireCurrentBusinessSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  );
  Future<void> handleAuthMessage(
    MessageData message, {
    required WebSocketSink sink,
    required PeerSocketSession session,
  });
  Future<bool> sendMessageData(
    MessageData message, {
    String? peerId,
    WebSocketSink? sink,
  });
  Future<bool> sendHeartbeatControl(
    String tag,
    String content,
    String peerId, {
    WebSocketSink? sink,
  });
  Future<void> sendHeartbeat({
    bool profileRefreshRequest = false,
    WebSocketSink? sink,
    String? peerId,
  });
  void setRemoteProfile(PeerProfile? profile, {String? peerId});
  void dispatchMessage(MessageData message);
  void dispatchConnect();
  Future<void> handleWorkspaceClipboardOffer({
    required String peerId,
    required String sessionId,
  });
  Future<void> handleWorkspaceClipboardClear({
    required String peerId,
    required String sessionId,
  });
  Future<void> relayWorkspaceClipboardText(
    MessageData message, {
    required String sourcePeerId,
  });
  Future<bool> sendWindowStreamControlTo(
    String peerId,
    WindowStreamControlMessage control,
  );
  Future<bool> sendFileBrowseControlTo(
    String peerId,
    FileBrowseMessage control,
  );
  Future<bool> sendAudioGroupControlTo(
    String peerId,
    AudioGroupControlMessage control,
  );
  Future<bool> sendRemoteInputControlTo(
    String peerId,
    RemoteInputControlMessage control,
  );
  void answerAudioDialBack(
    PeerSocketSession session,
    AudioGroupControlMessage request,
  );
  void answerInputDialBack(
    PeerSocketSession session,
    RemoteInputControlMessage request,
  );
  Future<void> releaseTerminalControl({
    required String namespace,
    required String route,
    required String peerId,
    required String sessionId,
  });
  void remoteInputTrace(String message);
  String remoteInputControlSummary(RemoteInputControlMessage control);
  String shortSessionId(String sessionId);
}
