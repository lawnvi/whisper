import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/clipboard/clipboard_sync_coordinator.dart';
import 'package:whisper/helper/clipboard_sync.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/notification.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/fs_protocol.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/socket/channel_router_host.dart';
export 'package:whisper/socket/channel_router_host.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_ping_tracker.dart';
import 'package:whisper/socket/peer_profile_refresh.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/transfer_channel_protocol.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/socket/wire_message_replay.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';
import 'package:whisper/window_stream/remote/window_stream_host.dart';
import 'package:whisper/window_stream/window_stream_support.dart';

/// Unified inbound `/chat` frame and message router.
///
/// Decodes [WhisperFrameV3] binary frames and JSON [MessageData] envelopes,
/// validates session/business invariants, and dispatches each subsystem message
/// to its coordinator.
class ChannelRouter {
  ChannelRouter(this._host);

  static final Set<String> _audioGroupControlActions = AudioGroupControlAction
      .values
      .map((action) => action.name)
      .toSet();
  static final Set<String> _remoteInputControlActions = RemoteInputControlAction
      .values
      .map((action) => action.name)
      .toSet();
  static final Set<String> _windowStreamControlActions =
      WindowStreamControlAction.values.map((action) => action.name).toSet();

  final ChannelRouterHost _host;

  Future<void> handlePayload(
    Uint8List data, {
    WebSocketSink? sink,
    bool allowFrame = true,
    required bool asServer,
    required PeerSocketSession session,
  }) async {
    if (allowFrame && WhisperFrameV3.looksLikeFrame(data)) {
      await _handleWhisperFrameV3(
        WhisperFrameV3.decode(data),
        sink: sink,
        asServer: asServer,
        session: session,
      );
      return;
    }
    final streamPeerId = _host.peers.peerIdForSink(sink);

    var str = '';
    var message = MessageData(
      id: 0,
      sender: _host.localSenderUid,
      receiver: '',
      name: '',
      clipboard: false,
      size: 0,
      type: MessageEnum.UNKONWN,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      uuid: '',
      acked: false,
      path: '',
      md5: '',
    );
    try {
      str = utf8.decode(data);
      final json = jsonDecode(str) as Map<String, dynamic>;
      message = decodeWireMessage(json);
    } catch (_) {
      // 需同时容忍 Error:type 以枚举序号上线,新版对端发来的越界序号
      // 会抛 RangeError(不是 Exception),此处降级为 UNKONWN 消息继续。
    }
    final incomingPeerId = session.isAuthenticated
        ? session.remotePeerId
        : (message.sender.isNotEmpty ? message.sender : streamPeerId);
    void requireCurrentBusiness() {
      if (!session.isAuthenticated || sink == null) {
        throw const WireInputRejected(WireInputReason.sessionNotCurrent);
      }
      _host.requireCurrentBusinessSession(
        session,
        sink,
        session.connectionGeneration,
      );
    }

    if (!session.isAuthenticated && message.type != MessageEnum.Auth) {
      throw const WireInputRejected(WireInputReason.sessionNotAuthenticated);
    }
    if (session.isAuthenticated) {
      requireCurrentBusiness();
      WireInputPolicy.validateMessage(
        message,
        authenticatedPeerId: session.remotePeerId,
        localPeerId: session.localProfile.uid,
      ).requireAccepted();
    }
    if (message.type == MessageEnum.Text && !message.clipboard) {
      final replay = await _claimIncomingTextMessage(
        message,
        requireCurrent: requireCurrentBusiness,
      );
      requireCurrentBusiness();
      switch (replay.decision) {
        case WireMessageReplayDecision.accept:
          message = replay.message!;
        case WireMessageReplayDecision.duplicate:
          message = replay.message!;
          _host.dispatchMessage(message);
          await ackMessage(message);
          return;
        case WireMessageReplayDecision.conflict:
          throw const AuthHandshakeException('message_uuid_conflict');
      }
    }

    switch (message.type) {
      case MessageEnum.Auth:
        if (sink == null) {
          session.close();
          return;
        }
        await _host.handleAuthMessage(message, sink: sink, session: session);
      case MessageEnum.Ack:
        await _handleAck(message, sink: sink, session: session);
      case MessageEnum.Text:
        await _handleText(
          message,
          session: session,
          requireCurrentBusiness: requireCurrentBusiness,
        );
      case MessageEnum.Notification:
        await _handleNotification(
          message,
          requireCurrentBusiness: requireCurrentBusiness,
        );
      case MessageEnum.Heartbeat:
        await _handleHeartbeat(
          message,
          sink: sink,
          incomingPeerId: incomingPeerId,
          requireCurrentBusiness: requireCurrentBusiness,
        );
      case MessageEnum.File:
      case MessageEnum.TransferControl:
      case MessageEnum.AudioControl:
        break;
      case MessageEnum.WindowStreamControl:
        await _handleWindowStreamControl(
          message,
          session: session,
          requireCurrentBusiness: requireCurrentBusiness,
        );
      case MessageEnum.FileBrowseControl:
        await _handleFileBrowseControl(
          message,
          session: session,
          requireCurrentBusiness: requireCurrentBusiness,
        );
      case MessageEnum.AudioGroupControl:
        await _handleAudioGroupControl(
          message,
          session: session,
          requireCurrentBusiness: requireCurrentBusiness,
        );
      case MessageEnum.RemoteInputControl:
        await _handleRemoteInputControl(
          message,
          session: session,
          requireCurrentBusiness: requireCurrentBusiness,
        );
      case MessageEnum.TransferChannelControl:
        requireCurrentBusiness();
        final control = TransferChannelControlMessage.parseWireMessage(
          message,
          authenticatedPeerId: session.remotePeerId,
          localPeerId: session.localProfile.uid,
        );
        await _host.handleTransferChannelControl(session, control);
      default:
        logger.i('未知消息：$str');
    }
  }

  Future<void> _handleWhisperFrameV3(
    WhisperFrameV3 frame, {
    WebSocketSink? sink,
    required bool asServer,
    required PeerSocketSession session,
  }) async {
    if (session.isAuthenticated) {
      if (sink == null) {
        throw const WireInputRejected(WireInputReason.sessionNotCurrent);
      }
      _host.requireCurrentBusinessSession(
        session,
        sink,
        session.connectionGeneration,
      );
      _host.pingTracker.noteInboundActivity(session.remotePeerId);
    }
    if (!session.isAuthenticated && frame.type != WhisperFrameType.message) {
      throw const WireInputRejected(WireInputReason.sessionNotAuthenticated);
    }
    if ((frame.type == WhisperFrameType.fileData ||
            frame.type == WhisperFrameType.browseData ||
            frame.type == WhisperFrameType.browseWrite) &&
        frame.payload.length > _host.maxFileDataPayloadBytes) {
      throw const WireInputRejected(WireInputReason.transferPayloadInvalid);
    }
    switch (frame.type) {
      case WhisperFrameType.message:
        WireInputPolicy.validateMessageFrame(frame).requireAccepted();
        await handlePayload(
          frame.payload,
          sink: sink,
          allowFrame: false,
          asServer: asServer,
          session: session,
        );
      case WhisperFrameType.fileOffer:
      case WhisperFrameType.fileData:
      case WhisperFrameType.fileReady:
      case WhisperFrameType.fileAck:
      case WhisperFrameType.fileComplete:
      case WhisperFrameType.fileCancel:
      case WhisperFrameType.fileError:
        await _host.transferEngine.handleFrame(
          TransferConnectionBinding(
            peerId: session.remotePeerId,
            generation: session.connectionGeneration,
          ),
          frame,
          requireCurrent: () => _host.requireCurrentBusinessSession(
            session,
            sink!,
            session.connectionGeneration,
          ),
        );
      case WhisperFrameType.clipboardOffer:
      case WhisperFrameType.clipboardRequest:
      case WhisperFrameType.clipboardClear:
      case WhisperFrameType.clipboardError:
        await _handleClipboardFrame(frame, session: session);
      case WhisperFrameType.browseData:
        RemoteFilesClient.handleData(
          remotePeerId: session.remotePeerId,
          sessionId: frame.transferId,
          requestId: frame.sequence,
          data: Uint8List.fromList(frame.payload),
        );
      case WhisperFrameType.browseWrite:
        unawaited(
          FileBrowseHost.shared
              .handleWrite(
                remotePeerId: session.remotePeerId,
                transferId: frame.transferId,
                requestId: frame.sequence,
                offset: frame.offset,
                data: Uint8List.fromList(frame.payload),
              )
              .catchError((Object error) {
                logger.i('挂载写入失败: ${error.runtimeType}');
              }),
        );
    }
  }

  Future<void> _handleClipboardFrame(
    WhisperFrameV3 frame, {
    required PeerSocketSession session,
  }) async {
    if (!(await LocalSetting().instance()).clipboard) {
      return;
    }
    final clipboardSessionId = _remoteClipboardFrameSessionId(frame);
    try {
      await _host.remoteClipboardTransfer.handleFrame(
        TransferConnectionBinding(
          peerId: session.remotePeerId,
          generation: session.connectionGeneration,
        ),
        frame,
        prepareImages:
            frame.type == WhisperFrameType.clipboardOffer &&
            await LocalSetting().clipboardAutoSync(),
      );
    } on Exception catch (error) {
      logClipboardSync(
        ClipboardSyncStep.frameDropped,
        kind: frame.type,
        error: error,
      );
      return;
    }
    if (frame.type == WhisperFrameType.clipboardOffer &&
        clipboardSessionId != null) {
      await _host.handleWorkspaceClipboardOffer(
        peerId: session.remotePeerId,
        sessionId: clipboardSessionId,
      );
    } else if (frame.type == WhisperFrameType.clipboardClear &&
        clipboardSessionId != null) {
      await _host.handleWorkspaceClipboardClear(
        peerId: session.remotePeerId,
        sessionId: clipboardSessionId,
      );
    }
  }

  String? _remoteClipboardFrameSessionId(WhisperFrameV3 frame) {
    if (frame.payload.length > 64 * 1024) return null;
    try {
      final value = jsonDecode(utf8.decode(frame.payload));
      if (value is Map && value['sessionId'] is String) {
        return value['sessionId'] as String;
      }
    } on Object {
      return null;
    }
    return null;
  }

  Future<void> _handleAck(
    MessageData message, {
    required WebSocketSink? sink,
    required PeerSocketSession session,
  }) async {
    if (sink == null) {
      throw const WireInputRejected(WireInputReason.sessionNotCurrent);
    }
    final acknowledged = await WireInputPolicy.acknowledgeOutgoing(
      database: _host.database,
      acknowledgement: message,
      authenticatedPeerId: session.remotePeerId,
      localPeerId: session.localProfile.uid,
      requireCurrent: () => _host.requireCurrentBusinessSession(
        session,
        sink,
        session.connectionGeneration,
      ),
    );
    if (acknowledged != null) {
      _host.outgoingTextAcknowledgements.acknowledge(
        session.remotePeerId,
        acknowledged.uuid,
      );
      _host.dispatchMessage(acknowledged);
    }
  }

  Future<void> _handleText(
    MessageData message, {
    required PeerSocketSession session,
    required void Function() requireCurrentBusiness,
  }) async {
    logger.i('收到文本消息, uuid: ${message.uuid}, clipboard: ${message.clipboard}');
    if (message.clipboard) {
      if ((await LocalSetting().instance()).clipboard) {
        logClipboardSync(ClipboardSyncStep.received);
        requireCurrentBusiness();
        await _host.relayWorkspaceClipboardText(
          message,
          sourcePeerId: session.remotePeerId,
        );
        requireCurrentBusiness();
        await ClipboardSyncCoordinator.shared.applyRemoteText(
          message.content ?? '',
        );
      }
      requireCurrentBusiness();
      await ackMessage(message);
      return;
    }
    requireCurrentBusiness();
    _host.dispatchMessage(message);
    await ackMessage(message);
  }

  Future<void> _handleNotification(
    MessageData message, {
    required void Function() requireCurrentBusiness,
  }) async {
    final decoded = jsonDecode(message.content ?? '{}');
    final data = decoded is Map ? decoded : const <String, Object?>{};
    final ignoreNotification = await LocalSetting().ignoreAndroidNotification();
    requireCurrentBusiness();
    if (!ignoreNotification && supportNotification() && data['text'] != null) {
      unawaited(
        NotificationHelper().showNotification(
          title: '【${data['app']}】 ${data['title']}',
          body: data['text'] ?? '',
        ),
      );
      if (isVerificationCodeNotificationPackage(data['package'])) {
        final code = verifyCode(
          '${data["title"] ?? ""}\n${data["text"] ?? ""}',
        );
        if (code.isNotEmpty && await LocalSetting().copyVerify()) {
          requireCurrentBusiness();
          await copyToClipboard(code);
        }
      }
    }
    requireCurrentBusiness();
    _host.dispatchMessage(message);
    await ackMessage(message);
  }

  Future<void> _handleHeartbeat(
    MessageData message, {
    required WebSocketSink? sink,
    required String? incomingPeerId,
    required void Function() requireCurrentBusiness,
  }) async {
    if (message.sender == _host.localSenderUid) {
      return;
    }
    final heartbeatPeerId = incomingPeerId ?? message.sender;
    if (message.message == heartbeatPingTag) {
      final pong = _host.pingTracker.buildPongPayload(message.content);
      if (pong != null && heartbeatPeerId.isNotEmpty) {
        unawaited(
          _host.sendHeartbeatControl(
            heartbeatPongTag,
            pong,
            heartbeatPeerId,
            sink: sink,
          ),
        );
      }
      return;
    }
    if (message.message == heartbeatPongTag) {
      if (heartbeatPeerId.isNotEmpty) {
        _host.pingTracker.completePong(heartbeatPeerId, message.content);
      }
      return;
    }
    await _refreshRemoteProfileFromHeartbeat(
      message,
      peerId: incomingPeerId,
      requireCurrent: requireCurrentBusiness,
    );
    requireCurrentBusiness();
    if (message.message == heartbeatProfileRequestTag) {
      unawaited(_host.sendHeartbeat(peerId: incomingPeerId, sink: sink));
    }
  }

  Future<void> _handleWindowStreamControl(
    MessageData message, {
    required PeerSocketSession session,
    required void Function() requireCurrentBusiness,
  }) async {
    final json = _decodeValidatedControl(
      message,
      allowedActions: _windowStreamControlActions,
    );
    final control = WindowStreamControlMessage.fromJson(json);
    _validateControlSessionAndPeers(
      messageId: message.uuid,
      sessionId: control.sessionId,
      sourcePeerId: control.viewerPeerId,
      sinkPeerId: control.hostPeerId,
      session: session,
    );
    final weAreHost = control.hostPeerId == session.localProfile.uid;
    if (control.isTerminal &&
        !control.isInitial &&
        !_host.wireControlSessions.knows(
          namespace: WindowStreamHost.namespace,
          sessionId: control.sessionId,
        )) {
      await ackMessage(message);
      return;
    }
    _host.wireControlSessions
        .validateAndRemember(
          namespace: WindowStreamHost.namespace,
          sessionId: control.sessionId,
          sourcePeerId: control.viewerPeerId,
          sinkPeerId: control.hostPeerId,
          authenticatedPeerId: session.remotePeerId,
          localPeerId: session.localProfile.uid,
          isInitialOffer: control.isInitial,
          isIncoming: weAreHost,
          reverseInitialDirection: !weAreHost && !control.isHostInitiated,
        )
        .requireAccepted();
    requireCurrentBusiness();
    final remoteDevice = _host.peers
        .requireRemoteProfileForSession(session)
        .device;
    var releaseLater = false;
    try {
      if (weAreHost) {
        final storedRemote = await _host.database.fetchDevice(remoteDevice.uid);
        requireCurrentBusiness();
        final trusted =
            storedRemote?.auth == true &&
            storedRemote?.identityPublicKey.isNotEmpty == true &&
            storedRemote?.identityPublicKey ==
                session.remoteIdentityPublicKey &&
            session.isAuthenticated;
        final remotePeerId = session.remotePeerId;
        Future<bool> reply(WindowStreamControlMessage outgoing) =>
            _host.sendWindowStreamControlTo(remotePeerId, outgoing);
        if (!trusted || !supportsWindowStreamSource()) {
          if (control.isInitial) {
            await reply(
              control.reply(
                WindowStreamControlAction.reject,
                payload: {'reason': trusted ? 'unsupported' : 'untrusted'},
              ),
            );
          }
        } else {
          releaseLater = control.isTerminal;
          unawaited(
            WindowStreamHost.shared
                .handleControl(control, remotePeerId: remotePeerId, send: reply)
                .catchError((Object error) {
                  logger.i('窗口流转请求失败: ${error.runtimeType}');
                })
                .whenComplete(() async {
                  if (releaseLater) {
                    await _host.releaseTerminalControl(
                      namespace: WindowStreamHost.namespace,
                      route: WindowStreamHost.route,
                      peerId: remotePeerId,
                      sessionId: control.sessionId,
                    );
                  }
                }),
          );
        }
      } else {
        session.withMediaSendKey(
          (sendKey) => session.withMediaReceiveKey(
            (receiveKey) => WindowStreamViewer.shared.handleControl(
              control,
              remotePeerId: session.remotePeerId,
              remoteHost: remoteDevice.host,
              sendKey: sendKey,
              receiveKey: receiveKey,
            ),
          ),
        );
      }
    } finally {
      if (control.isTerminal && !releaseLater) {
        await _host.releaseTerminalControl(
          namespace: WindowStreamHost.namespace,
          route: WindowStreamHost.route,
          peerId: session.remotePeerId,
          sessionId: control.sessionId,
        );
      }
    }
    requireCurrentBusiness();
    await ackMessage(message);
  }

  Future<void> _handleFileBrowseControl(
    MessageData message, {
    required PeerSocketSession session,
    required void Function() requireCurrentBusiness,
  }) async {
    final json = _decodeValidatedControl(
      message,
      allowedActions: FileBrowseMessage.allActions,
    );
    final control = FileBrowseMessage.fromJson(json);
    _validateControlSessionAndPeers(
      messageId: message.uuid,
      sessionId: control.sessionId,
      sourcePeerId: control.clientPeerId,
      sinkPeerId: control.hostPeerId,
      session: session,
    );
    final weAreHost = control.hostPeerId == session.localProfile.uid;
    _host.wireControlSessions
        .validateAndRemember(
          namespace: _host.fileBrowseNamespace,
          sessionId: control.sessionId,
          sourcePeerId: control.clientPeerId,
          sinkPeerId: control.hostPeerId,
          authenticatedPeerId: session.remotePeerId,
          localPeerId: session.localProfile.uid,
          isInitialOffer: control.isInitial,
          isIncoming: weAreHost,
          reverseInitialDirection: !weAreHost,
        )
        .requireAccepted();
    requireCurrentBusiness();
    final remoteDevice = _host.peers
        .requireRemoteProfileForSession(session)
        .device;
    final remotePeerId = session.remotePeerId;
    if (weAreHost) {
      final trusted = await _host.fileBrowseTrustCache.isTrusted(
        session,
        _host.database.fetchDevice,
      );
      requireCurrentBusiness();
      if (!trusted) {
        if (control.isInitial) {
          await _host.sendFileBrowseControlTo(
            remotePeerId,
            control.reply(FileBrowseAction.denied),
          );
        }
      } else {
        unawaited(
          FileBrowseHost.shared
              .handle(
                control,
                remotePeerId: remotePeerId,
                deviceName: remoteDevice.label,
              )
              .catchError((Object error) {
                logger.i('文件浏览请求失败: ${error.runtimeType}');
              }),
        );
      }
    } else {
      RemoteFilesClient.handle(control, remotePeerId: remotePeerId);
    }
    if (control.isTerminal) {
      _host.wireControlSessions.forget(
        namespace: _host.fileBrowseNamespace,
        sessionId: control.sessionId,
      );
    }
    requireCurrentBusiness();
    await ackMessage(message);
  }

  Future<void> _handleAudioGroupControl(
    MessageData message, {
    required PeerSocketSession session,
    required void Function() requireCurrentBusiness,
  }) async {
    final json = _decodeValidatedControl(
      message,
      allowedActions: _audioGroupControlActions,
    );
    final control = AudioGroupControlMessage.fromJson(json);
    _validateControlSessionAndPeers(
      messageId: message.uuid,
      sessionId: control.sessionId,
      sourcePeerId: control.sourcePeerId,
      sinkPeerId: control.sinkPeerId,
      session: session,
    );
    if (control.action.mayOutliveSession &&
        !_host.wireControlSessions.knows(
          namespace: 'audio-group',
          sessionId: control.sessionId,
        )) {
      requireCurrentBusiness();
      await ackMessage(message);
      return;
    }
    _host.wireControlSessions
        .validateAndRemember(
          namespace: 'audio-group',
          sessionId: control.sessionId,
          sourcePeerId: control.sourcePeerId,
          sinkPeerId: control.sinkPeerId,
          authenticatedPeerId: session.remotePeerId,
          localPeerId: session.localProfile.uid,
          isInitialOffer:
              control.action == AudioGroupControlAction.groupOffer ||
              control.action == AudioGroupControlAction.sinkJoinRequest,
          isIncoming: true,
          reverseInitialDirection:
              control.action == AudioGroupControlAction.sinkJoinRequest,
          context: '${control.groupId}\u0000${control.streamId}',
        )
        .requireAccepted();
    if (control.action == AudioGroupControlAction.groupDialBack) {
      _host.answerAudioDialBack(session, control);
      await ackMessage(message);
      return;
    }
    final self = await LocalSetting().instance();
    requireCurrentBusiness();
    final remoteDevice = _host.peers
        .requireRemoteProfileForSession(session)
        .device;
    final isTerminal =
        control.action == AudioGroupControlAction.groupReject ||
        control.action == AudioGroupControlAction.groupStop ||
        control.action == AudioGroupControlAction.error;
    try {
      await session.withMediaSendKeyAsync(
        (mediaSendKey) => AudioGroupCoordinator.shared.handleControlMessage(
          control,
          localPeerId: self.uid,
          remoteHost: remoteDevice.host,
          remotePort: remoteDevice.port,
          mediaSendKey: mediaSendKey,
          sendControl: (_, control) =>
              _host.sendAudioGroupControlTo(session.remotePeerId, control),
        ),
      );
    } finally {
      if (isTerminal) {
        await _host.releaseTerminalControl(
          namespace: 'audio-group',
          route: '/audio',
          peerId: session.remotePeerId,
          sessionId: control.sessionId,
        );
      }
    }
    requireCurrentBusiness();
    await ackMessage(message);
  }

  Future<void> _handleRemoteInputControl(
    MessageData message, {
    required PeerSocketSession session,
    required void Function() requireCurrentBusiness,
  }) async {
    final json = _decodeValidatedControl(
      message,
      allowedActions: _remoteInputControlActions,
    );
    final control = RemoteInputControlMessage.fromJson(json);
    _validateControlSessionAndPeers(
      messageId: message.uuid,
      sessionId: control.sessionId,
      sourcePeerId: control.sourcePeerId,
      sinkPeerId: control.sinkPeerId,
      session: session,
    );
    _host.wireControlSessions
        .validateAndRemember(
          namespace: 'remote-input',
          sessionId: control.sessionId,
          sourcePeerId: control.sourcePeerId,
          sinkPeerId: control.sinkPeerId,
          authenticatedPeerId: session.remotePeerId,
          localPeerId: session.localProfile.uid,
          isInitialOffer: control.action == RemoteInputControlAction.offer,
          isIncoming: true,
        )
        .requireAccepted();
    if (control.action == RemoteInputControlAction.dialBack) {
      _host.answerInputDialBack(session, control);
      await ackMessage(message);
      return;
    }
    final self = await LocalSetting().instance();
    requireCurrentBusiness();
    final remoteDevice = _host.peers
        .requireRemoteProfileForSession(session)
        .device;
    final storedRemote = await _host.database.fetchDevice(remoteDevice.uid);
    requireCurrentBusiness();
    final authenticatedSession = _host.peers.sessionForPeer(remoteDevice.uid);
    final isMutuallyTrusted =
        storedRemote?.auth == true &&
        storedRemote?.identityPublicKey.isNotEmpty == true &&
        storedRemote?.identityPublicKey ==
            authenticatedSession?.remoteIdentityPublicKey &&
        authenticatedSession?.isAuthenticated == true;
    final remoteProfile = _host.peers.requireRemoteProfileForSession(session);
    final manual = control.mode == RemoteInputMode.manual;
    final manualAllowed =
        supportsManualRemoteInputSink() &&
        remoteProfile.capabilities.remoteInputManualSourceV1;
    final localCanInject = manual ? manualAllowed : supportsNativeRemoteInput();
    _host.remoteInputTrace(
      'remote input recv control ${_host.remoteInputControlSummary(control)} '
      'local=${self.uid} '
      'remote=${remoteDevice.uid} '
      'remoteAddress=${remoteDevice.host}:${remoteDevice.port} '
      'storedAuth=${storedRemote?.auth == true} '
      'signedSession=${authenticatedSession?.isAuthenticated == true} '
      'mutualTrust=$isMutuallyTrusted '
      'localCanInject=$localCanInject '
      'remoteSupports=${_host.peers.supportsRemoteInputFor(remoteDevice.uid)}',
    );
    final isTerminal =
        control.action == RemoteInputControlAction.reject ||
        control.action == RemoteInputControlAction.stop ||
        control.action == RemoteInputControlAction.error;
    try {
      final handledByWorkspace = await session.withMediaSendKeyAsync(
        (mediaSendKey) =>
            RemoteInputWorkspaceCoordinator.shared.handleControlMessage(
              control,
              localPeerId: self.uid,
              remoteHost: remoteDevice.host,
              remotePort: remoteDevice.port,
              mediaSendKey: mediaSendKey,
              sendControlTo: (peerId, control) =>
                  _host.sendRemoteInputControlTo(peerId, control),
            ),
      );
      requireCurrentBusiness();
      if (handledByWorkspace) {
        await ackMessage(message);
        return;
      }
      await session.withMediaSendKeyAsync(
        (mediaSendKey) => RemoteInputCoordinator.shared.handleControlMessage(
          control,
          localPeerId: self.uid,
          remoteHost: remoteDevice.host,
          remotePort: remoteDevice.port,
          isMutuallyTrusted: isMutuallyTrusted,
          localCanInject: localCanInject,
          mediaSendKey: mediaSendKey,
          sendControl: (control) =>
              _host.sendRemoteInputControlTo(session.remotePeerId, control),
          remotePlatform: remoteDevice.platform,
        ),
      );
      requireCurrentBusiness();
      final inputState = RemoteInputCoordinator.shared.state;
      _host.remoteInputTrace(
        'remote input handled control ${_host.remoteInputControlSummary(control)} '
        'state=${inputState.role.name}/${inputState.status.name} '
        'stateSession=${_host.shortSessionId(inputState.sessionId)} '
        'statePeer=${inputState.peerId} '
        'stateError=${inputState.errorMessage}',
      );
      await ackMessage(message);
    } finally {
      if (isTerminal) {
        await _host.releaseTerminalControl(
          namespace: 'remote-input',
          route: '/input',
          peerId: session.remotePeerId,
          sessionId: control.sessionId,
        );
      }
    }
  }

  Map<String, dynamic> _decodeValidatedControl(
    MessageData message, {
    required Set<String> allowedActions,
  }) {
    final json = jsonDecode(message.content ?? '{}') as Map<String, dynamic>;
    WireInputPolicy.validateControlEnvelope(
      json,
      allowedActions: allowedActions,
    ).requireAccepted();
    return json;
  }

  void _validateControlSessionAndPeers({
    required String messageId,
    required String sessionId,
    required String sourcePeerId,
    required String sinkPeerId,
    required PeerSocketSession session,
  }) {
    WireInputPolicy.validateControlSessionId(
      messageId: messageId,
      sessionId: sessionId,
    ).requireAccepted();
    WireInputPolicy.validatePeerPair(
      sourcePeerId: sourcePeerId,
      sinkPeerId: sinkPeerId,
      authenticatedPeerId: session.remotePeerId,
      localPeerId: session.localProfile.uid,
    ).requireAccepted();
  }

  Future<WireMessageReplayClaim> _claimIncomingTextMessage(
    MessageData incoming, {
    void Function()? requireCurrent,
  }) async {
    return _host.wireMessageReplayGuard.claim(
      incoming,
      fetchExisting: _host.database.fetchMessagesByUuid,
      hasExternalClaim: (uuid) async =>
          await _host.database.fetchFileTransfer(uuid) != null,
      persist: (message) {
        requireCurrent?.call();
        return _host.database.insertMessageReturning(message, acked: false);
      },
    );
  }

  Future<void> _refreshRemoteProfileFromHeartbeat(
    MessageData message, {
    String? peerId,
    void Function()? requireCurrent,
  }) async {
    try {
      final resolvedPeerId = peerId ?? message.sender;
      final previousProfile = resolvedPeerId.isEmpty
          ? null
          : _host.peers.remoteProfileFor(resolvedPeerId);
      final profile = PeerProfileRefreshTracker.decodeHeartbeatProfile(
        message.content,
        resolvedPeerId: resolvedPeerId,
        previousProfile: previousProfile,
      );
      if (profile == null) return;
      requireCurrent?.call();
      final profileDeviceChanged = PeerProfileRefreshTracker.deviceChanged(
        previousProfile?.device,
        profile.device,
      );
      _host.setRemoteProfile(profile, peerId: resolvedPeerId);
      if (profile.device.uid.isNotEmpty) {
        requireCurrent?.call();
        await _host.database.upsertDevice(profile.device);
        requireCurrent?.call();
        if (_host.manageSharedCoordinators &&
            _host.peers.isConnectedTo(profile.device.uid)) {
          ConnectionCoordinator().markConnected(
            profile.device,
            select:
                ConnectionCoordinator().snapshot.activePeerId == resolvedPeerId,
          );
        }
        if (profileDeviceChanged) {
          _host.dispatchConnect();
        }
      }
    } on WireInputRejected {
      rethrow;
    } catch (error) {
      _host.remoteInputTrace('heartbeat profile parse failed: $error');
    }
  }

  Future<void> ackMessage(MessageData data) async {
    if (data.type != MessageEnum.Text && data.type != MessageEnum.File) {
      return;
    }
    final json = data.toJson();
    json['type'] = MessageEnum.Ack.index;
    json['acked'] = true;
    json['sender'] = data.receiver;
    json['receiver'] = data.sender;
    await sendAcknowledgementBestEffort(
      send: () =>
          _host.sendMessageData(decodeWireMessage(json), peerId: data.sender),
      onError: (error, stackTrace) {
        logger.i('send acknowledgement failed: ${error.runtimeType}');
      },
    );
  }
}
