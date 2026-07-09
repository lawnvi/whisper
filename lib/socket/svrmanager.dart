import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_share_coordinator.dart';
import 'package:whisper/audio/audio_protocol.dart';
import 'package:whisper/audio/audio_share_manager.dart';
import 'package:whisper/helper/clipboard_sync.dart';
import 'package:whisper/helper/connection_request_notifications.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/whisper_file_picker.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/auth_request_gate.dart';
import 'package:whisper/socket/auth_protocol.dart';
import 'package:whisper/socket/device_identity.dart';
import 'package:whisper/socket/dial_tiebreaker.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/peer_transfer_runtime.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/state/peer_profile.dart';
import 'package:path/path.dart' as p;

import '../helper/file.dart';
import '../helper/notification.dart';

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

final class _SocketAuthResult {
  const _SocketAuthResult(this.allow, this.message);

  final bool allow;
  final String message;
}

typedef _IdentityPinPlan = ({
  PairingReason? reason,
  String expectedPublicKey,
});

class WsSvrManager {
  static const Duration _serverPingInterval = Duration(seconds: 45);
  static const Duration _clientHeartbeatInterval = Duration(seconds: 15);

  static const String _profileRefreshRequestMessage = 'profile-refresh-request';
  static const String duplicateAuthRequestMessage = '连接请求正在等待对方确认';
  // 创建一个私有的静态实例变量
  static final WsSvrManager _singleton = WsSvrManager._internal();

  // 私有构造函数，阻止类被直接实例化
  WsSvrManager._internal();

  // 工厂构造函数，返回单例实例
  factory WsSvrManager() {
    return _singleton;
  }

  Uuid uuid = LocalUuid;

  HttpServer? _server;
  WebSocketSink? _sink;
  final PeerConnectionRegistry _peerConnections = PeerConnectionRegistry();
  final Map<WebSocketSink, String> _peerIdsBySink = <WebSocketSink, String>{};
  final Map<WebSocketSink, PeerSocketSession> _sessionsBySink =
      <WebSocketSink, PeerSocketSession>{};
  final Map<String, PeerSocketSession> _sessionsByPeerId =
      <String, PeerSocketSession>{};
  final Map<WebSocketSink, Completer<_SocketAuthResult>> _authResultsBySink =
      <WebSocketSink, Completer<_SocketAuthResult>>{};
  final Map<WebSocketSink, ({String host, int port})> _endpointsBySink =
      <WebSocketSink, ({String host, int port})>{};
  final DeviceIdentityStore _identityStore = DeviceIdentityStore();
  int _nextConnectionGeneration = 0;
  final AuthRequestGate _authRequestGate = AuthRequestGate();
  final Map<WebSocketSink, String> _outgoingAuthKeysBySink =
      <WebSocketSink, String>{};
  final Map<WebSocketSink, String> _incomingAuthPeerIdsBySink =
      <WebSocketSink, String>{};
  final Map<WebSocketSink, _IdentityPinPlan> _identityPinPlansBySink =
      <WebSocketSink, _IdentityPinPlan>{};
  final Map<String, PeerProfile> _remoteProfilesByPeerId =
      <String, PeerProfile>{};
  final Map<WebSocketSink, Timer> _clientTimersBySink =
      <WebSocketSink, Timer>{};
  final Set<ISocketEvent> _listeners = <ISocketEvent>{};
  ISocketEvent? _primaryEvent;
  bool started = false;
  String receiver = "";
  String sender = "";
  Future<void> _receiveQueue = Future<void>.value();
  Timer? _clientTimer;
  PeerProfile? _remoteProfile;
  int _remoteProfileRevision = 0;
  final List<Completer<PeerProfile?>> _remoteProfileRefreshWaiters =
      <Completer<PeerProfile?>>[];
  late final FileTransferEngine _transferEngine = FileTransferEngine(
    sendBytesToPeer: _sendBytesToPeer,
    emitTransferUpdated: (snapshot) =>
        _dispatchToAll((event) => event.onTransferUpdated(snapshot)),
    notify: (message) => _dispatchToAll((event) => event.onNotice(message)),
    remoteProfileFor: (peerId) =>
        _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null),
    isConnectedTo: isConnectedTo,
    connectedPeerIds: () => _peerConnections.connectedPeerIds,
    defaultPeerId: () => receiver,
    hasLegacySinkFor: (peerId) => peerId == receiver && _sink != null,
    buildMessage: _buildMessage,
    dispatchOutgoingMessage: _dispatchOutgoingMessage,
    ackMessage: _ackMessage,
  );

  PeerProfile? get _selectedRemoteProfile =>
      _remoteProfilesByPeerId[receiver] ?? _remoteProfile;

  Set<String> get connectedPeerIds => _peerConnections.connectedPeerIds;
  bool get isConnected =>
      _sink != null || _peerConnections.connectedPeerIds.isNotEmpty;
  bool get supportsFileTransferV3 =>
      _selectedRemoteProfile?.capabilities.fileTransferV3 == true;
  bool get supportsRemoteInput =>
      _selectedRemoteProfile?.capabilities.remoteInputSourceV1 == true &&
      _selectedRemoteProfile?.capabilities.remoteInputSinkV1 == true;
  bool get supportsRemoteInputTopology =>
      supportsRemoteInput &&
      _selectedRemoteProfile?.capabilities.remoteInputTopologyV1 == true &&
      _selectedRemoteProfile?.displayTopology?.isNotEmpty == true;
  RemoteInputTopology? get remoteDisplayTopology =>
      _selectedRemoteProfile?.displayTopology;

  bool supportsRemoteInputFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.capabilities.remoteInputSourceV1 == true &&
        profile?.capabilities.remoteInputSinkV1 == true;
  }

  PeerProfile? remoteProfileFor(String peerId) {
    return _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
  }

  bool supportsAudioGroupSourceFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.capabilities.audioGroupSourceV1 == true;
  }

  bool supportsAudioGroupSinkFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.capabilities.audioGroupSinkV1 == true;
  }

  List<DeviceData> connectedAudioGroupSinkDevices({
    String preferredPeerId = '',
  }) {
    final devices = <DeviceData>[];
    for (final peerId in connectedPeerIds) {
      if (!supportsAudioGroupSinkFor(peerId)) {
        continue;
      }
      final profile = _remoteProfilesByPeerId[peerId] ??
          (peerId == receiver ? _remoteProfile : null);
      final device = profile?.device;
      if (device != null) {
        devices.add(device);
      }
    }
    devices.sort((left, right) {
      if (left.uid == preferredPeerId) {
        return -1;
      }
      if (right.uid == preferredPeerId) {
        return 1;
      }
      return left.name.compareTo(right.name);
    });
    return devices;
  }

  List<DeviceData> connectedRemoteInputDevices({
    String preferredPeerId = '',
  }) {
    final devices = <DeviceData>[];
    for (final peerId in connectedPeerIds) {
      if (!supportsRemoteInputFor(peerId)) {
        continue;
      }
      final profile = _remoteProfilesByPeerId[peerId] ??
          (peerId == receiver ? _remoteProfile : null);
      final device = profile?.device;
      if (device != null) {
        devices.add(device);
      }
    }
    devices.sort((left, right) {
      if (left.uid == preferredPeerId) {
        return -1;
      }
      if (right.uid == preferredPeerId) {
        return 1;
      }
      return left.name.compareTo(right.name);
    });
    return devices;
  }

  bool supportsRemoteInputTopologyFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return supportsRemoteInputFor(peerId) &&
        profile?.capabilities.remoteInputTopologyV1 == true &&
        profile?.displayTopology?.isNotEmpty == true;
  }

  RemoteInputTopology? remoteDisplayTopologyFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.displayTopology;
  }

  bool remoteTrustsPeer(String peerId) {
    final selectedPeerId = _selectedRemoteProfile?.device.uid ?? receiver;
    return peerId == sender &&
        _sessionsByPeerId[selectedPeerId]?.isAuthenticated == true;
  }

  bool remotePeerTrustsPeer(String remotePeerId, String trustedPeerId) {
    return trustedPeerId == sender &&
        _sessionsByPeerId[remotePeerId]?.isAuthenticated == true;
  }

  bool isConnectedTo(String peerId) {
    return _peerConnections.isConnectedTo(peerId);
  }

  void selectPeer(String peerId) {
    if (!_peerConnections.isConnectedTo(peerId)) {
      return;
    }
    receiver = peerId;
  }

  String _shortSessionId(String sessionId) {
    if (sessionId.length <= 8) {
      return sessionId;
    }
    return sessionId.substring(0, 8);
  }

  String _remoteInputControlSummary(RemoteInputControlMessage control) {
    return 'action=${control.action.name} '
        'session=${_shortSessionId(control.sessionId)} '
        'source=${control.sourcePeerId} '
        'sink=${control.sinkPeerId} '
        'edge=${control.layoutEdge?.name ?? '-'} '
        'path=${control.path} '
        'reason=${control.releaseReason} '
        'error=${control.errorMessage}';
  }

  void _remoteInputTrace(String message) {
    logger.i(message);
    if (!kReleaseMode ||
        Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] == '1') {
      debugPrint(message);
    }
  }

  String? _peerIdForSink(WebSocketSink? sink) {
    return sink == null ? null : _peerIdsBySink[sink];
  }

  void setSender(String uid) {
    sender = uid;
  }

  void setEvent(ISocketEvent event) {
    _listeners
      ..clear()
      ..add(event);
    _primaryEvent = event;
  }

  void registerEvent(
    ISocketEvent event, {
    String uid = "",
    bool primary = false,
  }) {
    _listeners.add(event);
    if (_primaryEvent == null || primary) {
      _primaryEvent = event;
    }
    if (uid.isNotEmpty) {
      sender = uid;
    }
  }

  void unregisterEvent([ISocketEvent? event]) {
    if (event == null) {
      return;
    }
    _listeners.remove(event);
    if (identical(_primaryEvent, event)) {
      _primaryEvent = _listeners.isEmpty ? null : _listeners.first;
    }
  }

  void _dispatchToAll(void Function(ISocketEvent event) callback) {
    final listeners = _listeners.toList(growable: false);
    for (final listener in listeners) {
      _dispatchGuarded(listener, callback);
    }
  }

  void _dispatchToPrimary(void Function(ISocketEvent event) callback) {
    final primaryEvent = _primaryEvent;
    if (primaryEvent != null) {
      _dispatchGuarded(primaryEvent, callback);
    }
  }

  // 单个监听器异常只记日志,不得阻断协议事件继续分发给其余监听器。
  void _dispatchGuarded(
    ISocketEvent listener,
    void Function(ISocketEvent event) callback,
  ) {
    try {
      callback(listener);
    } catch (error, stackTrace) {
      logger.i('socket 事件监听器异常: $error\n$stackTrace');
    }
  }

  void debugResetListeners() {
    _listeners.clear();
    _primaryEvent = null;
  }

  void debugDispatchMessage(MessageData messageData) {
    _dispatchToAll((event) => event.onMessage(messageData));
  }

  void debugDispatchTransfer(TransferSnapshot snapshot) {
    _dispatchToAll((event) => event.onTransferUpdated(snapshot));
  }

  String _authRequestKey({
    String? peerId,
    required String host,
    required int port,
  }) {
    final normalizedPeerId = peerId?.trim() ?? '';
    if (normalizedPeerId.isNotEmpty) {
      return 'peer:$normalizedPeerId';
    }
    return 'endpoint:${host.trim()}:$port';
  }

  void _releaseOutgoingAuthForSink(WebSocketSink? sink) {
    if (sink == null) {
      return;
    }
    final requestKey = _outgoingAuthKeysBySink.remove(sink);
    if (requestKey != null) {
      _authRequestGate.releaseOutgoing(requestKey);
    }
  }

  void _releaseIncomingAuthForSink(WebSocketSink? sink) {
    if (sink == null) {
      return;
    }
    final peerId = _incomingAuthPeerIdsBySink.remove(sink);
    if (peerId != null && peerId.isNotEmpty) {
      _authRequestGate.releaseIncoming(peerId);
      _ignoreFuture(
        ConnectionRequestNotifier().dismissForPeer(
          peerId,
          graceMillis: 3000,
        ),
        context: 'dismiss pairing notification',
      );
    }
  }

  void _ignoreFuture(Future<void> future, {required String context}) {
    unawaited(future.catchError((Object error, StackTrace stackTrace) {
      logger.i('$context failed: $error\n$stackTrace');
    }));
  }

  Future<void> debugRegisterPeerConnection(
    String peerId,
    PeerConnection connection,
  ) async {
    await _peerConnections.register(connection);
    if (receiver.isEmpty) {
      receiver = peerId;
    }
  }

  Future<void> _registerPeerConnection({
    required String peerId,
    required WebSocketSink sink,
    required PeerSocketSession session,
    PeerProfile? profile,
  }) async {
    if (peerId.isEmpty || !session.isAuthenticationReady) {
      return;
    }
    _peerIdsBySink[sink] = peerId;
    await _peerConnections.register(
      PeerConnection(
        peerId: peerId,
        connectionId: session.connectionGeneration,
        send: (message) {
          if (session.isAuthenticated) {
            _sendBytesOnSink(sink, message);
          }
        },
        close: () async {
          _peerIdsBySink.remove(sink);
          session.close();
          await sink.close();
        },
      ),
    );
    receiver = peerId;
    _sink = sink;
    _setRemoteProfile(profile, peerId: peerId);
  }

  Future<void> _handlePeerSocketDoneQueued(WebSocketSink sink) {
    _receiveQueue = _receiveQueue.then((_) async {
      try {
        await _handlePeerSocketDone(sink);
      } catch (error, stackTrace) {
        logger.i('处理 websocket 关闭失败: $error\n$stackTrace');
      }
    });
    return _receiveQueue;
  }

  Future<void> _handlePeerSocketDone(WebSocketSink sink) async {
    final session = _sessionsBySink.remove(sink);
    session?.close();
    _endpointsBySink.remove(sink);
    _identityPinPlansBySink.remove(sink);
    _completeSocketAuth(sink, false, 'connection_closed');
    _releaseOutgoingAuthForSink(sink);
    _releaseIncomingAuthForSink(sink);
    _clientTimersBySink.remove(sink)?.cancel();
    final peerId = _peerIdsBySink.remove(sink);
    final isCurrentConnection = peerId != null &&
        session != null &&
        identical(_sessionsByPeerId[peerId], session);
    if (isCurrentConnection) {
      _sessionsByPeerId.remove(peerId);
    }
    if (peerId == null) {
      if (identical(_sink, sink)) {
        _sink = null;
      }
      return;
    }
    if (!isCurrentConnection ||
        !await _peerConnections.removeIfCurrent(
          peerId,
          session.connectionGeneration,
        )) {
      return;
    }
    await _handlePeerDisconnected(peerId);
    _remoteProfilesByPeerId.remove(peerId);
    if (receiver == peerId) {
      receiver = _peerConnections.connectedPeerIds.isEmpty
          ? ''
          : _peerConnections.connectedPeerIds.first;
      if (receiver.isEmpty) {
        _sink = null;
        _setRemoteProfile(null);
      } else {
        _setRemoteProfile(_remoteProfilesByPeerId[receiver], peerId: receiver);
      }
    }
    _dispatchToAll((event) => event.onClose());
  }

  Future<PeerSocketSession> _createSocketSession({
    required WebSocketSink sink,
    required PeerSocketRole role,
    String intendedPeerId = '',
    String intendedPublicKeyHash = '',
  }) async {
    late PeerSocketSession session;
    session = await PeerSocketSession.create(
      role: role,
      connectionGeneration: ++_nextConnectionGeneration,
      localIdentity: await _identityStore.loadOrCreate(),
      localProfile: (await _localPeerProfile()).toWireProfile(),
      intendedPeerId: intendedPeerId,
      intendedPublicKeyHash: intendedPublicKeyHash,
      onTimeout: () {
        if (!identical(_sessionsBySink[sink], session)) {
          return;
        }
        _completeSocketAuth(sink, false, 'pairing_expired');
        _ignoreFuture(sink.close(), context: 'close expired pairing socket');
      },
    );
    _sessionsBySink[sink] = session;
    return session;
  }

  Future<void> _attachIncomingSocket(WebSocketChannel webSocket) async {
    final sink = webSocket.sink;
    try {
      await _createSocketSession(sink: sink, role: PeerSocketRole.server);
      webSocket.stream.listen((message) {
        unawaited(
          _handleIncomingMessage(message, sink: sink, asServer: true),
        );
      }, onError: (Object error, StackTrace stackTrace) {
        _sessionsBySink[sink]?.close();
        logger.i('连接服务异常: ${error.runtimeType}');
        _dispatchToPrimary((event) => event.onError(error.toString()));
        _completeSocketAuth(sink, false, 'socket_error');
        unawaited(_handlePeerSocketDoneQueued(sink));
      }, onDone: () {
        _sessionsBySink[sink]?.close();
        unawaited(_handlePeerSocketDoneQueued(sink));
      });
    } catch (error) {
      _completeSocketAuth(sink, false, 'session_setup_failed');
      await sink.close();
    }
  }

  void _completeSocketAuth(WebSocketSink sink, bool allow, String message) {
    final completer = _authResultsBySink.remove(sink);
    if (completer != null && !completer.isCompleted) {
      completer.complete(_SocketAuthResult(allow, message));
    }
  }

  Future<void> _failSocketSession(
    PeerSocketSession session,
    WebSocketSink sink,
    String message,
  ) async {
    session.close();
    _identityPinPlansBySink.remove(sink);
    _completeSocketAuth(sink, false, message);
    _releaseOutgoingAuthForSink(sink);
    _releaseIncomingAuthForSink(sink);
    try {
      await sink.close();
    } catch (error, stackTrace) {
      logger.i('关闭失败的 websocket 失败: $error\n$stackTrace');
    }
  }

  void startServer(int port, var callback) {
    close(closeServer: true);
    AudioShareManager.shared.onGroupPacket = (packet) {
      unawaited(AudioGroupCoordinator.shared.handlePacket(packet));
    };
    final chatHandler = webSocketHandler((WebSocketChannel webSocket) {
      unawaited(_attachIncomingSocket(webSocket));
    }, pingInterval: _serverPingInterval);
    final audioHandler = AudioShareManager.shared.webSocketHandler(
      pingInterval: _serverPingInterval,
    );
    final remoteInputHandler = RemoteInputManager.shared.webSocketHandler(
      pingInterval: _serverPingInterval,
    );

    FutureOr<shelf.Response> handler(shelf.Request request) {
      if (request.url.path == 'audio') {
        return audioHandler(request);
      }
      if (request.url.path == 'input') {
        return remoteInputHandler(request);
      }
      return chatHandler(request);
    }

    shelf_io.serve(handler, '0.0.0.0', port, shared: true).then((server) {
      _server = server;
      started = true;
      var host = "${server.address.host}:${server.port}";
      logger.i('Serving at ws://$host');
      callback(true, "");
    }).onError((error, stackTrace) {
      logger.i("服务启动失败: $error\n$stackTrace");
      callback(false, error);
    });
  }

  Future<void> connectToServer(
    String host,
    int port,
    var callback, {
    String? peerId,
    String? intendedPublicKeyHash,
  }) async {
    final authRequestKey = _authRequestKey(
      peerId: peerId,
      host: host,
      port: port,
    );
    if (!_authRequestGate.tryClaimOutgoing(authRequestKey)) {
      callback(false, duplicateAuthRequestMessage);
      return;
    }
    WebSocketChannel? channel;
    try {
      final wsUrl = Uri.parse('ws://$host:$port');
      channel = IOWebSocketChannel(
        WebSocket.connect(
          wsUrl.toString(),
          compression: CompressionOptions.compressionOff,
        ),
      );
      final connectedChannel = channel;
      await connectedChannel.ready;
      final channelSink = connectedChannel.sink;
      _outgoingAuthKeysBySink[channelSink] = authRequestKey;
      _endpointsBySink[channelSink] = (host: host, port: port);
      final authCompleter = Completer<_SocketAuthResult>();
      _authResultsBySink[channelSink] = authCompleter;
      final session = await _createSocketSession(
        sink: channelSink,
        role: PeerSocketRole.client,
        intendedPeerId: peerId ?? '',
        intendedPublicKeyHash: intendedPublicKeyHash ?? '',
      );
      connectedChannel.stream.listen((message) {
        unawaited(
          _handleIncomingMessage(message, sink: channelSink, asServer: false),
        );
      }, onError: (error, stackTrace) {
        _sessionsBySink[channelSink]?.close();
        logger.i('客户端服务异常: ${error.runtimeType}');
        _dispatchToPrimary((event) => event.onError(error.toString()));
        _completeSocketAuth(channelSink, false, 'socket_error');
        unawaited(_handlePeerSocketDoneQueued(channelSink));
      }, onDone: () {
        _sessionsBySink[channelSink]?.close();
        unawaited(_handlePeerSocketDoneQueued(channelSink));
      });
      await _sendAuthEnvelope(channelSink, await session.createHello());
      final authResult = await authCompleter.future;
      _releaseOutgoingAuthForSink(channelSink);
      if (!authResult.allow) {
        await channelSink.close();
        callback(false, authResult.message);
        return;
      }
      final timer = Timer.periodic(_clientHeartbeatInterval, (timer) {
        unawaited(_heartBeat(sink: channelSink));
      });
      _clientTimersBySink[channelSink] = timer;
      _clientTimer = timer;
      callback(true, "");
    } on Exception catch (e1) {
      if (channel != null) {
        _completeSocketAuth(channel.sink, false, 'connection_failed');
        _releaseOutgoingAuthForSink(channel.sink);
      } else {
        _authRequestGate.releaseOutgoing(authRequestKey);
      }
      callback(false, "连接失败：$e1");
    }
  }

  Future<void> closeGracefully({
    bool closeServer = false,
    bool forceServerClose = false,
  }) async {
    final hadActiveConnection = _sink != null ||
        _clientTimer != null ||
        _sessionsBySink.isNotEmpty ||
        _authResultsBySink.isNotEmpty ||
        _peerConnections.connectedPeerIds.isNotEmpty ||
        receiver.isNotEmpty;
    if (!hadActiveConnection && !closeServer) {
      return;
    }

    _clientTimer?.cancel();
    _clientTimer = null;
    for (final timer in _clientTimersBySink.values) {
      timer.cancel();
    }
    _clientTimersBySink.clear();
    _outgoingAuthKeysBySink.clear();
    _incomingAuthPeerIdsBySink.clear();
    _identityPinPlansBySink.clear();
    _authRequestGate.clear();
    for (final entry in _authResultsBySink.entries.toList(growable: false)) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          const _SocketAuthResult(false, 'connection_closed'),
        );
      }
    }
    _authResultsBySink.clear();
    for (final session in _sessionsBySink.values) {
      session.close();
    }
    _sessionsBySink.clear();
    _sessionsByPeerId.clear();
    _endpointsBySink.clear();
    await _transferEngine.closeAll();
    await AudioShareCoordinator.shared.stopLocal();
    await AudioGroupCoordinator.shared.stopLocal();
    await RemoteInputWorkspaceCoordinator.shared.stopControllerWorkspace(
      sendControlTo: sendRemoteInputControlTo,
    );
    await RemoteInputCoordinator.shared.stopLocal();
    _sink = null;
    await _peerConnections.disconnectAll();
    _peerIdsBySink.clear();
    _remoteProfilesByPeerId.clear();
    if (closeServer) {
      started = false;
      final server = _server;
      _server = null;
      await server?.close(force: forceServerClose);
    }
    _remoteProfile = null;
    _completeRemoteProfileRefreshWaiters();
    receiver = "";
    logger.i("服务已关闭");
    _dispatchToAll((event) => event.onClose());
  }

  Future<void> disconnectPeer(String peerId) async {
    if (peerId.isEmpty || !_peerConnections.isConnectedTo(peerId)) {
      return;
    }
    await _peerConnections.disconnect(peerId);
    await _handlePeerDisconnected(peerId);
    _remoteProfilesByPeerId.remove(peerId);
    if (receiver == peerId) {
      receiver = _peerConnections.connectedPeerIds.isEmpty
          ? ''
          : _peerConnections.connectedPeerIds.first;
      _sink = receiver.isEmpty ? null : _sink;
      _setRemoteProfile(
        receiver.isEmpty ? null : _remoteProfilesByPeerId[receiver],
        peerId: receiver.isEmpty ? null : receiver,
      );
    }
    _dispatchToAll((event) => event.onClose());
  }

  Future<void> _handlePeerDisconnected(String peerId) async {
    await _transferEngine.handlePeerDisconnected(peerId);
    await RemoteInputWorkspaceCoordinator.shared.handlePeerDisconnected(peerId);
    if (RemoteInputCoordinator.shared.state.isForPeer(peerId)) {
      await RemoteInputCoordinator.shared.stopLocal();
    }
  }

  void close({bool closeServer = false}) {
    unawaited(closeGracefully(closeServer: closeServer));
  }

  bool _sendTo(String peerId, Object message) {
    if (peerId.isEmpty) {
      return false;
    }
    return _peerConnections.sendTo(peerId, message);
  }

  void _sendBytesOnSink(
    WebSocketSink sink,
    Object message, {
    bool rawAuth = false,
  }) {
    if (rawAuth) {
      sink.add(message);
      return;
    }
    final session = _sessionsBySink[sink];
    if (session == null || !session.isAuthenticated) {
      unawaited(sink.close());
      return;
    }
    final Uint8List bytes;
    if (message is Uint8List) {
      bytes = message;
    } else if (message is List<int>) {
      bytes = Uint8List.fromList(message);
    } else if (message is String) {
      bytes = Uint8List.fromList(utf8.encode(message));
    } else {
      unawaited(sink.close());
      return;
    }
    unawaited(_encodeAndSend(session, sink, bytes));
  }

  Future<void> _encodeAndSend(
    PeerSocketSession session,
    WebSocketSink sink,
    Uint8List bytes,
  ) async {
    try {
      sink.add(await session.encodeOutgoing(bytes));
    } catch (_) {
      session.close();
      await sink.close();
    }
  }

  Uint8List _messageFrame(Uint8List payload) {
    return WhisperFrameV3(
      type: WhisperFrameType.message,
      transferId: '',
      offset: 0,
      sequence: 0,
      payload: payload,
    ).encode();
  }

  void _sendMessageData(
    MessageData message, {
    String? peerId,
    WebSocketSink? sink,
    bool rawAuth = false,
  }) {
    final payload = WhisperFrameV3(
      type: WhisperFrameType.message,
      transferId: '',
      offset: 0,
      sequence: 0,
      payload: Uint8List.fromList(utf8.encode(encodeWireMessage(message))),
    ).encode();
    if (sink != null) {
      _sendBytesOnSink(sink, payload, rawAuth: rawAuth);
      return;
    }
    if (peerId != null && _peerConnections.sendTo(peerId, payload)) {
      return;
    }
    _send(encodeWireMessage(message));
  }

  void _dispatchOutgoingMessage(MessageData message) {
    _dispatchToAll((event) => event.onMessage(message));
  }

  bool _sendBytesToPeer(String peerId, Object bytes) {
    if (peerId.isNotEmpty && _peerConnections.sendTo(peerId, bytes)) {
      return true;
    }
    if (peerId.isEmpty || peerId == receiver) {
      final sink = _sink;
      if (sink != null) {
        _sendBytesOnSink(sink, bytes);
      }
      return _sink != null;
    }
    return false;
  }

  void _send(String message) {
    final payload = _messageFrame(Uint8List.fromList(utf8.encode(message)));
    if (!_sendTo(receiver, payload)) {
      final sink = _sink;
      if (sink != null) {
        _sendBytesOnSink(sink, payload);
      }
    }
  }

  /// [asServer] 是本条 socket 的角色(服务端接入=true/本机拨出=false),
  /// 随消息逐层透传;设备可同时对不同 peer 兼具两种角色,不存在全局角色。
  Future<void> _handleIncomingMessage(
    dynamic message, {
    WebSocketSink? sink,
    required bool asServer,
  }) {
    _receiveQueue = _receiveQueue.then((_) async {
      try {
        final session = sink == null ? null : _sessionsBySink[sink];
        if (session == null ||
            (asServer && session.role != PeerSocketRole.server) ||
            (!asServer && session.role != PeerSocketRole.client)) {
          await sink?.close();
          return;
        }
        var bytes = _incomingBytes(message);
        if (session.isAuthenticated) {
          bytes = await session.decodeIncoming(bytes);
        }
        await _listen(
          bytes,
          sink: sink,
          asServer: asServer,
          session: session,
        );
      } catch (error) {
        logger.i('处理 websocket 消息失败: ${error.runtimeType}');
        final failedSession = sink == null ? null : _sessionsBySink[sink];
        if (sink != null && failedSession != null) {
          final message = error is AuthHandshakeException
              ? error.code
              : 'authentication_failed';
          await _failSocketSession(failedSession, sink, message);
        } else {
          await sink?.close();
        }
      }
    });
    return _receiveQueue;
  }

  Uint8List _incomingBytes(dynamic message) {
    if (message is Uint8List) {
      return message;
    }
    if (message is List<int>) {
      return Uint8List.fromList(message);
    }
    if (message is String) {
      return Uint8List.fromList(utf8.encode(message));
    }
    throw FormatException('unsupported websocket message: $message');
  }

  Future<void> _sendAuthEnvelope(
    WebSocketSink sink,
    AuthEnvelope envelope,
  ) async {
    final message = _buildMessage(
      MessageEnum.Auth,
      envelope.toJsonString(),
      '',
      '',
      0,
      false,
      senderOverride: _sessionsBySink[sink]?.localProfile.uid,
      receiverOverride: envelope.action == AuthAction.hello
          ? envelope.intendedPeerId ?? ''
          : _sessionsBySink[sink]?.remotePeerId,
    );
    _sendMessageData(message, sink: sink, rawAuth: true);
  }

  Future<void> _handleAuthMessage(
    MessageData message, {
    required WebSocketSink sink,
    required PeerSocketSession session,
  }) async {
    try {
      final content = message.content;
      if (content == null || content.isEmpty) {
        throw const FormatException('Missing auth envelope');
      }
      final envelope = AuthEnvelope.fromJsonString(content);
      if (message.sender.isNotEmpty && message.sender != envelope.peerId) {
        throw const AuthHandshakeException('sender_mismatch');
      }
      switch ((session.role, envelope.action)) {
        case (PeerSocketRole.server, AuthAction.hello):
          await _handleServerHello(session, sink, envelope);
        case (PeerSocketRole.server, AuthAction.proof):
          await _handleServerProof(session, sink, envelope);
        case (PeerSocketRole.client, AuthAction.challenge):
          await _handleClientChallenge(session, sink, envelope);
        case (PeerSocketRole.client, AuthAction.result):
          await _handleClientResult(session, sink, envelope);
        default:
          throw const AuthHandshakeException('unexpected_action');
      }
    } on FormatException {
      if (session.role == PeerSocketRole.server) {
        _sendUpgradeRequired(sink, session);
      }
      await _failSocketSession(session, sink, 'upgrade_required');
    } on AuthHandshakeException catch (error) {
      if (error.code == 'upgrade_required' &&
          session.role == PeerSocketRole.server) {
        _sendUpgradeRequired(sink, session);
      }
      await _failSocketSession(session, sink, error.code);
    }
  }

  Future<void> _handleServerHello(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope hello,
  ) async {
    final challenge = await session.receiveHello(hello);
    await _sendAuthEnvelope(sink, challenge);
  }

  Future<void> _handleClientChallenge(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope challenge,
  ) async {
    await session.receiveChallenge(challenge);
    final pinPlan = await _pairingReason(session);
    final generation = session.connectionGeneration;
    Future<void> resolve(bool allow) async {
      final accepted = session.resolveLocalApproval(
        generation: generation,
        allow: allow,
      );
      if (!accepted || !_isSameSession(session, sink, generation)) {
        return;
      }
      if (!allow) {
        _completeSocketAuth(sink, false, 'rejected');
        _dispatchToAll((event) => event.afterAuth(false, null));
        await sink.close();
        return;
      }
      if (!_isCurrentSession(session, sink, generation)) {
        return;
      }
      final proof = await session.createProof();
      if (!_isCurrentSession(session, sink, generation)) {
        return;
      }
      _identityPinPlansBySink[sink] = pinPlan;
      await _sendAuthEnvelope(sink, proof);
    }

    if (pinPlan.reason == null) {
      await resolve(true);
    } else {
      await _requestPairingDecision(
        session,
        sink,
        pinPlan.reason!,
        resolve,
      );
    }
  }

  Future<void> _handleServerProof(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope proof,
  ) async {
    await session.receiveProof(proof);
    final peerId = session.remotePeerId;
    final outgoingKey = _authRequestKey(peerId: peerId, host: '', port: 0);
    if (_authRequestGate.hasOutgoing(outgoingKey)) {
      final decision = resolveSimultaneousDial(
        localUid: session.localProfile.uid,
        remoteUid: peerId,
      );
      if (decision == SimultaneousDialDecision.keepOutgoing) {
        session.close();
        await sink.close();
        return;
      }
    }
    if (!_authRequestGate.tryClaimIncoming(peerId)) {
      session.close();
      await sink.close();
      return;
    }
    _incomingAuthPeerIdsBySink[sink] = peerId;

    final pinPlan = await _pairingReason(session);
    final generation = session.connectionGeneration;
    Future<void> resolve(bool allow) async {
      final accepted = session.resolveLocalApproval(
        generation: generation,
        allow: allow,
      );
      if (!accepted || !_isCurrentSession(session, sink, generation)) {
        return;
      }
      final result = await session.createResult(
        allow: allow,
        reason: allow ? 'approved' : 'rejected',
      );
      if (!_isSameSession(session, sink, generation)) {
        return;
      }
      if (!allow) {
        await _sendAuthEnvelope(sink, result);
        _releaseIncomingAuthForSink(sink);
        _dispatchToAll((event) => event.afterAuth(false, null));
        await sink.close();
        return;
      }
      if (!_isCurrentSession(session, sink, generation)) {
        return;
      }
      final storedDevice = await _completeAuthenticatedSession(
        session,
        sink,
        pinPlan: pinPlan,
      );
      _requireCurrentAuthenticatedSession(session, sink, generation);
      await _sendAuthEnvelope(sink, result);
      _announceAuthenticatedSession(session, sink, storedDevice);
    }

    if (pinPlan.reason == null) {
      await resolve(true);
    } else {
      await _requestPairingDecision(
        session,
        sink,
        pinPlan.reason!,
        resolve,
      );
    }
  }

  Future<void> _handleClientResult(
    PeerSocketSession session,
    WebSocketSink sink,
    AuthEnvelope result,
  ) async {
    if (!await session.receiveResult(result)) {
      _identityPinPlansBySink.remove(sink);
      _completeSocketAuth(sink, false, result.reason ?? 'rejected');
      _dispatchToAll((event) => event.afterAuth(false, null));
      await sink.close();
      return;
    }
    final pinPlan = _identityPinPlansBySink.remove(sink);
    if (pinPlan == null) {
      throw const AuthHandshakeException('identity_pin_state_missing');
    }
    final storedDevice = await _completeAuthenticatedSession(
      session,
      sink,
      pinPlan: pinPlan,
    );
    _announceAuthenticatedSession(session, sink, storedDevice);
  }

  Future<_IdentityPinPlan> _pairingReason(PeerSocketSession session) async {
    final stored = await LocalDatabase().fetchDevice(session.remotePeerId);
    return (
      reason: pairingReasonForIdentity(stored, session.remoteIdentityPublicKey),
      expectedPublicKey: stored?.identityPublicKey ?? '',
    );
  }

  Future<void> _requestPairingDecision(
    PeerSocketSession session,
    WebSocketSink sink,
    PairingReason reason,
    Future<void> Function(bool) resolve,
  ) async {
    final listener = _primaryEvent;
    if (listener == null) {
      await resolve(false);
      return;
    }
    final generation = session.connectionGeneration;
    final device = await _deviceForSession(session, sink);
    if (!_isCurrentSession(session, sink, generation)) {
      return;
    }
    _ignoreFuture(
      ConnectionRequestNotifier().maybeShowForPairing(
        peerId: session.remotePeerId,
      ),
      context: 'show pairing notification',
    );
    final guarded = session.guardApprovalCallback((allow) {
      _runGuardedApproval(
        session: session,
        sink: sink,
        generation: generation,
        resolve: () => resolve(allow),
      );
    });
    _dispatchGuarded(
      listener,
      (event) => event.onPairing(
        PairingRequest(
          device: device,
          pairingCode: session.pairingCode,
          reason: reason,
          canApprove: true,
        ),
        guarded,
      ),
    );
  }

  void _runGuardedApproval({
    required PeerSocketSession session,
    required WebSocketSink sink,
    required int generation,
    required Future<void> Function() resolve,
  }) {
    unawaited(() async {
      try {
        await resolve();
      } catch (error, stackTrace) {
        logger.i('处理配对决定失败: $error\n$stackTrace');
        if (_isSameSession(session, sink, generation)) {
          await _failSocketSession(
            session,
            sink,
            error is AuthHandshakeException
                ? error.code
                : 'authentication_failed',
          );
        }
      }
    }());
  }

  Future<DeviceData> _deviceForSession(
    PeerSocketSession session,
    WebSocketSink sink,
  ) async {
    final stored = await LocalDatabase().fetchDevice(session.remotePeerId);
    final endpoint = _endpointsBySink[sink];
    final host =
        endpoint?.host.isNotEmpty == true ? endpoint!.host : stored?.host ?? '';
    final port = endpoint?.port != null && endpoint!.port > 0
        ? endpoint.port
        : stored?.port ?? 0;
    return session.remoteProfile!.toDeviceData(host: host, port: port);
  }

  Future<DeviceData> _completeAuthenticatedSession(
    PeerSocketSession session,
    WebSocketSink sink, {
    required _IdentityPinPlan pinPlan,
  }) async {
    final generation = session.connectionGeneration;
    _requireCurrentSession(session, sink, generation);
    DeviceData? storedDevice;
    PeerProfile? runtimeProfile;
    final committed = await session.commitAuthentication(
      generation: generation,
      persistIdentity: () async {
        _requireCurrentSession(session, sink, generation);
        final candidate = await _deviceForSession(session, sink);
        _requireCurrentSession(session, sink, generation);
        final database = LocalDatabase();
        final device = await database.commitAuthenticatedDevice(
          candidate: candidate,
          publicKey: session.remoteIdentityPublicKey,
          replaceIdentity: pinPlan.reason == PairingReason.identityChanged,
          expectedPublicKey: pinPlan.expectedPublicKey,
          requireCurrent: () =>
              _requireCurrentSession(session, sink, generation),
        );
        storedDevice = device;
        runtimeProfile = PeerProfile(
          device: device,
          trustedPeerIds: const <String>[],
          autoApproveNewDevices: false,
          autoConnectEnabled: true,
          protocolVersion: session.remoteProfile!.protocolVersion,
          capabilities: session.remoteProfile!.capabilities,
          displayTopology: session.remoteProfile!.displayTopology,
        );
      },
      registerPeer: () async {
        _requireCurrentRegisterableSession(session, sink, generation);
        final peerId = session.remotePeerId;
        _sessionsByPeerId[peerId] = session;
        await _registerPeerConnection(
          peerId: peerId,
          sink: sink,
          session: session,
          profile: runtimeProfile,
        );
        _requireCurrentRegisterableSession(session, sink, generation);
      },
    );
    if (!committed) {
      throw const AuthHandshakeException('session_expired');
    }
    _requireCurrentAuthenticatedSession(session, sink, generation);
    final device = storedDevice;
    if (device == null) {
      throw const AuthHandshakeException('identity_pin_state_missing');
    }
    return device;
  }

  void _announceAuthenticatedSession(
    PeerSocketSession session,
    WebSocketSink sink,
    DeviceData storedDevice,
  ) {
    _requireCurrentAuthenticatedSession(
      session,
      sink,
      session.connectionGeneration,
    );
    _releaseOutgoingAuthForSink(sink);
    _releaseIncomingAuthForSink(sink);
    _completeSocketAuth(sink, true, '');
    _dispatchToAll((event) => event.onConnect());
    _dispatchToAll((event) => event.afterAuth(true, storedDevice));
    _ignoreFuture(
      _transferEngine.resumeRecoverableOutgoing(),
      context: 'resume outgoing transfers',
    );
  }

  bool _isSameSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    return identical(_sessionsBySink[sink], session) &&
        session.connectionGeneration == generation;
  }

  bool _isCurrentSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    return _isSameSession(session, sink, generation) && !session.isClosed;
  }

  void _requireCurrentSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    if (!_isCurrentSession(session, sink, generation)) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  void _requireCurrentAuthenticatedSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    _requireCurrentSession(session, sink, generation);
    if (!session.isAuthenticated) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  void _requireCurrentRegisterableSession(
    PeerSocketSession session,
    WebSocketSink sink,
    int generation,
  ) {
    _requireCurrentSession(session, sink, generation);
    if (!session.isAuthenticationReady) {
      throw const AuthHandshakeException('session_expired');
    }
  }

  void _sendUpgradeRequired(
    WebSocketSink sink,
    PeerSocketSession session,
  ) {
    final payload = jsonEncode(<String, Object?>{
      'action': 'upgrade_required',
      'version': PeerSocketSession.protocolVersion,
    });
    final message = _buildMessage(
      MessageEnum.Auth,
      payload,
      'upgrade_required',
      '',
      0,
      false,
      senderOverride: session.localProfile.uid,
      receiverOverride: session.remotePeerId,
    );
    _sendMessageData(message, sink: sink, rawAuth: true);
  }

  Future<void> _handleWhisperFrameV3(
    WhisperFrameV3 frame, {
    WebSocketSink? sink,
    required bool asServer,
    required PeerSocketSession session,
  }) async {
    if (!session.isAuthenticated && frame.type != WhisperFrameType.message) {
      session.close();
      await sink?.close();
      return;
    }
    switch (frame.type) {
      case WhisperFrameType.message:
        await _listen(
          frame.payload,
          sink: sink,
          allowFrame: false,
          asServer: asServer,
          session: session,
        );
        break;
      case WhisperFrameType.fileOffer:
      case WhisperFrameType.fileData:
      case WhisperFrameType.fileReady:
      case WhisperFrameType.fileAck:
      case WhisperFrameType.fileComplete:
      case WhisperFrameType.fileCancel:
      case WhisperFrameType.fileError:
        await _transferEngine.handleFrame(frame);
        break;
    }
  }

  Future<void> _listen(
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
    final streamPeerId = _peerIdForSink(sink);

    String str = "";
    MessageData message = MessageData(
        id: 0,
        sender: sender,
        receiver: receiver,
        name: "",
        clipboard: false,
        size: 0,
        type: MessageEnum.UNKONWN,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        uuid: '',
        acked: false,
        path: '',
        md5: '');
    try {
      str = utf8.decode(data);
      Map<String, dynamic> json = jsonDecode(str);
      message = decodeWireMessage(json);
    } catch (_) {
      // 需同时容忍 Error:type 以枚举序号上线,新版对端发来的越界序号
      // 会抛 RangeError(不是 Exception),此处降级为 UNKONWN 消息继续。
    }
    final incomingPeerId =
        message.sender.isNotEmpty ? message.sender : streamPeerId;

    if (!session.isAuthenticated && message.type != MessageEnum.Auth) {
      session.close();
      await sink?.close();
      return;
    }

    switch (message.type) {
      case MessageEnum.Auth:
        {
          if (sink == null) {
            session.close();
            return;
          }
          await _handleAuthMessage(message, sink: sink, session: session);
          break;
        }
      case MessageEnum.Ack:
        {
          if (message.uuid.isEmpty) {
            return;
          }
          // logger.i("收到ACK消息: ${message.uuid} ${message.type}\n$str");
          var msg = await LocalDatabase().ackMessage(message);
          if (msg != null) {
            _dispatchToAll((event) => event.onMessage(msg));
          }
          break;
        }
      case MessageEnum.Text:
        {
          logger.i(
              "收到消息：${message.content} sender: ${message.sender} receiver: ${message.receiver}");
          await LocalDatabase().insertMessage(message);
          _ackMessage(message);
          if (message.clipboard) {
            if ((await LocalSetting().instance()).clipboard) {
              copyToClipboard(
                message.content ?? "",
                suppressWatcher: true,
              );
            }
          }
          _dispatchToAll((event) => event.onMessage(message));
          logger.i("文本消息：$str");
          break;
        }
      case MessageEnum.Notification:
        {
          var data = jsonDecode(message.content ?? "{}");
          if (!await LocalSetting().ignoreAndroidNotification()) {
            if (supportNotification() && data['text'] != null) {
              NotificationHelper().showNotification(
                  title: "【${data['app']}】 ${data['title']}",
                  body: data['text'] ?? "");
              if (isVerificationCodeNotificationPackage(data['package'])) {
                var code =
                    verifyCode('${data["title"] ?? ""}\n${data["text"] ?? ""}');
                if (code.isNotEmpty && await LocalSetting().copyVerify()) {
                  copyToClipboard(code);
                }
              }
            }
          }
          _ackMessage(message);
          _dispatchToAll((event) => event.onMessage(message));
          break;
        }
      case MessageEnum.Heartbeat:
        {
          if (message.sender == sender) {
            return;
          }
          await _refreshRemoteProfileFromHeartbeat(
            message,
            peerId: incomingPeerId,
          );
          if (message.message == _profileRefreshRequestMessage) {
            unawaited(_heartBeat(peerId: incomingPeerId, sink: sink));
          }
          _ackMessage(message);
          break;
        }
      case MessageEnum.File:
        // WSP2 可续传接收协议已删除,新版对端只通过 WhisperFrameV3
        // (fileOffer/fileData/...) 传输文件,纯 JSON 的 File 消息不再处理。
        break;
      case MessageEnum.TransferControl:
        // WSP2 可续传控制协议已删除,枚举值保留以兼容历史存储数据。
        break;
      case MessageEnum.AudioControl:
        {
          final json =
              jsonDecode(message.content ?? "{}") as Map<String, dynamic>;
          final control = AudioControlMessage.fromJson(json);
          final self = await LocalSetting().instance();
          final remoteProfile = incomingPeerId == null
              ? _selectedRemoteProfile
              : _remoteProfilesByPeerId[incomingPeerId] ??
                  _selectedRemoteProfile;
          final remoteDevice = remoteProfile?.device;
          await AudioShareCoordinator.shared.handleControlMessage(
            control,
            localPeerId: self.uid,
            remoteHost: remoteDevice?.host ?? '',
            remotePort: remoteDevice?.port ?? 0,
            sendControl: incomingPeerId == null
                ? sendAudioControl
                : (control) => sendAudioControlTo(incomingPeerId, control),
          );
          _ackMessage(message);
          break;
        }
      case MessageEnum.AudioGroupControl:
        {
          final json =
              jsonDecode(message.content ?? "{}") as Map<String, dynamic>;
          final control = AudioGroupControlMessage.fromJson(json);
          final self = await LocalSetting().instance();
          final remoteProfile = incomingPeerId == null
              ? _selectedRemoteProfile
              : _remoteProfilesByPeerId[incomingPeerId] ??
                  _selectedRemoteProfile;
          final remoteDevice = remoteProfile?.device;
          await AudioGroupCoordinator.shared.handleControlMessage(
            control,
            localPeerId: self.uid,
            remoteHost: remoteDevice?.host ?? '',
            remotePort: remoteDevice?.port ?? 0,
            sendControl: incomingPeerId == null
                ? (_, control) => sendAudioGroupControl(control)
                : (_, control) =>
                    sendAudioGroupControlTo(incomingPeerId, control),
          );
          _ackMessage(message);
          break;
        }
      case MessageEnum.RemoteInputControl:
        {
          final json =
              jsonDecode(message.content ?? "{}") as Map<String, dynamic>;
          final control = RemoteInputControlMessage.fromJson(json);
          final self = await LocalSetting().instance();
          final remoteProfile = incomingPeerId == null
              ? _selectedRemoteProfile
              : _remoteProfilesByPeerId[incomingPeerId] ??
                  _selectedRemoteProfile;
          final remoteDevice = remoteProfile?.device;
          final storedRemote = remoteDevice == null
              ? null
              : await LocalDatabase().fetchDevice(remoteDevice.uid);
          final authenticatedSession =
              remoteDevice == null ? null : _sessionsByPeerId[remoteDevice.uid];
          final isMutuallyTrusted = storedRemote?.auth == true &&
              storedRemote?.identityPublicKey.isNotEmpty == true &&
              storedRemote?.identityPublicKey ==
                  authenticatedSession?.remoteIdentityPublicKey &&
              authenticatedSession?.isAuthenticated == true;
          final localCanInject = supportsNativeRemoteInput();
          _remoteInputTrace(
            'remote input recv control ${_remoteInputControlSummary(control)} '
            'local=${self.uid} '
            'remote=${remoteDevice?.uid ?? ''} '
            'remoteAddress=${remoteDevice?.host ?? ''}:${remoteDevice?.port ?? 0} '
            'storedAuth=${storedRemote?.auth == true} '
            'signedSession=${authenticatedSession?.isAuthenticated == true} '
            'mutualTrust=$isMutuallyTrusted '
            'localCanInject=$localCanInject '
            'remoteSupports=$supportsRemoteInput',
          );
          final handledByWorkspaceBusy = await RemoteInputWorkspaceCoordinator
              .shared
              .handleIncomingOfferIfBusy(
            control,
            localPeerId: self.uid,
            sendControlTo: (_, control) => incomingPeerId == null
                ? sendRemoteInputControl(control)
                : sendRemoteInputControlTo(incomingPeerId, control),
          );
          if (handledByWorkspaceBusy) {
            _ackMessage(message);
            break;
          }
          final handledByWorkspace =
              await RemoteInputWorkspaceCoordinator.shared.handleControlMessage(
            control,
            localPeerId: self.uid,
            remoteHost: remoteDevice?.host ?? '',
            remotePort: remoteDevice?.port ?? 0,
            sendControlTo: (peerId, control) =>
                sendRemoteInputControlTo(peerId, control),
          );
          if (handledByWorkspace) {
            _ackMessage(message);
            break;
          }
          await RemoteInputCoordinator.shared.handleControlMessage(
            control,
            localPeerId: self.uid,
            remoteHost: remoteDevice?.host ?? '',
            remotePort: remoteDevice?.port ?? 0,
            isMutuallyTrusted: isMutuallyTrusted,
            localCanInject: localCanInject,
            sendControl: incomingPeerId == null
                ? sendRemoteInputControl
                : (control) =>
                    sendRemoteInputControlTo(incomingPeerId, control),
            remotePlatform: remoteDevice?.platform ?? '',
          );
          final inputState = RemoteInputCoordinator.shared.state;
          _remoteInputTrace(
            'remote input handled control ${_remoteInputControlSummary(control)} '
            'state=${inputState.role.name}/${inputState.status.name} '
            'stateSession=${_shortSessionId(inputState.sessionId)} '
            'statePeer=${inputState.peerId} '
            'stateError=${inputState.errorMessage}',
          );
          _ackMessage(message);
          break;
        }
      default:
        {
          logger.i("未知消息：$str");
        }
    }
  }

  MessageData _buildMessage(
      MessageEnum type, String content, msg, fileName, int size, bool clipboard,
      {String md5 = "",
      path = "",
      uid,
      fileTimestamp = 0,
      String? senderOverride,
      String? receiverOverride}) {
    return MessageData(
        id: 0,
        sender: senderOverride ?? sender,
        receiver: receiverOverride ?? receiver,
        name: fileName,
        clipboard: clipboard,
        size: size,
        type: type,
        content: content,
        message: msg,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        acked: false,
        uuid: uid ?? uuid.v4(),
        path: path,
        md5: md5,
        fileTimestamp: fileTimestamp);
  }

  Future<PeerProfile> _localPeerProfile() async {
    var device = await LocalSetting().instance(online: true);
    RemoteInputTopology? topology;
    if (supportsNativeRemoteInput()) {
      try {
        topology = await RemoteInputCoordinator.shared.displayTopology();
      } catch (error) {
        _remoteInputTrace('display topology unavailable: $error');
      }
    }
    final hasTopology = topology?.isNotEmpty == true;
    final profile = PeerProfile(
      device: device,
      trustedPeerIds: const <String>[],
      autoApproveNewDevices: false,
      autoConnectEnabled: true,
      protocolVersion: PeerSocketSession.protocolVersion,
      capabilities: PeerCapabilities(
        fileTransferV3: true,
        systemAudioSourceV1: supportsNativeSystemAudio(),
        speakerSinkV1: true,
        remoteInputSourceV1: supportsNativeRemoteInput(),
        remoteInputSinkV1: supportsNativeRemoteInput(),
        remoteInputTopologyV1: hasTopology,
        audioGroupSourceV1: supportsNativeSystemAudio(),
        audioGroupSinkV1: true,
        audioGroupRejoinV1: true,
        audioSyncClockV1: true,
        audioChannelRoleV1: true,
      ),
      displayTopology: topology,
    );
    return profile;
  }

  Future<PeerProfile?> requestRemoteProfileRefresh({
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    if (_sink == null) {
      return _remoteProfile;
    }

    final startRevision = _remoteProfileRevision;
    final completer = Completer<PeerProfile?>();
    _remoteProfileRefreshWaiters.add(completer);
    final timer = Timer(timeout, () {
      _remoteProfileRefreshWaiters.remove(completer);
      if (!completer.isCompleted) {
        completer.complete(_remoteProfile);
      }
    });

    try {
      await _heartBeat(profileRefreshRequest: true);
      if (_remoteProfileRevision != startRevision && !completer.isCompleted) {
        _remoteProfileRefreshWaiters.remove(completer);
        completer.complete(_remoteProfile);
      }
    } catch (_) {
      _remoteProfileRefreshWaiters.remove(completer);
      timer.cancel();
      if (!completer.isCompleted) {
        completer.complete(_remoteProfile);
      }
    }

    return completer.future.whenComplete(timer.cancel);
  }

  void _setRemoteProfile(PeerProfile? profile, {String? peerId}) {
    if (peerId != null && peerId.isNotEmpty) {
      if (profile == null) {
        _remoteProfilesByPeerId.remove(peerId);
      } else {
        _remoteProfilesByPeerId[peerId] = profile;
      }
    } else if (profile == null) {
      _remoteProfilesByPeerId.clear();
    }
    _remoteProfile = profile;
    _remoteProfileRevision++;
    _completeRemoteProfileRefreshWaiters();
  }

  void _completeRemoteProfileRefreshWaiters() {
    final waiters = _remoteProfileRefreshWaiters.toList(growable: false);
    _remoteProfileRefreshWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(_remoteProfile);
      }
    }
  }

  bool _profileDeviceChanged(DeviceData? previous, DeviceData next) {
    if (previous == null) {
      return true;
    }
    return previous.name != next.name ||
        previous.host != next.host ||
        previous.port != next.port ||
        previous.platform != next.platform;
  }

  Future<void> _refreshRemoteProfileFromHeartbeat(
    MessageData message, {
    String? peerId,
  }) async {
    final content = message.content;
    if (content == null || content.isEmpty) {
      return;
    }
    try {
      final resolvedPeerId = peerId ?? message.sender;
      final previousProfile = resolvedPeerId.isEmpty
          ? _remoteProfile
          : _remoteProfilesByPeerId[resolvedPeerId];
      final wireJson = Map<String, Object?>.from(
        jsonDecode(content) as Map,
      );
      final wireProfile = WirePeerProfile.fromJson(wireJson);
      final profile = PeerProfile.fromWire(
        wireProfile,
        host: previousProfile?.device.host ?? '',
        port: previousProfile?.device.port ?? 0,
      );
      final profileDeviceChanged =
          _profileDeviceChanged(previousProfile?.device, profile.device);
      _setRemoteProfile(profile, peerId: resolvedPeerId);
      if (profile.device.uid.isNotEmpty) {
        await LocalDatabase().upsertDevice(profile.device);
        if (_peerConnections.isConnectedTo(profile.device.uid)) {
          ConnectionCoordinator().markConnected(profile.device);
        }
        if (profileDeviceChanged) {
          _dispatchToAll((event) => event.onConnect());
        }
      }
    } catch (error) {
      _remoteInputTrace('heartbeat profile parse failed: $error');
    }
  }

  void _ackMessage(MessageData data) {
    var json = data.toJson();
    json["type"] = MessageEnum.Ack.index;
    json["acked"] = true;
    // logger.i("ack消息, ${data.type.name} uuid: ${data.uuid}");
    _sendMessageData(decodeWireMessage(json), peerId: data.sender);
  }

  Future<void> _heartBeat({
    bool profileRefreshRequest = false,
    WebSocketSink? sink,
    String? peerId,
  }) async {
    if (sink == null && peerId == null && _sink == null) {
      return;
    }
    final profile = await _localPeerProfile();
    var message = _buildMessage(
        MessageEnum.Heartbeat,
        profile.toJsonString(),
        profileRefreshRequest ? _profileRefreshRequestMessage : "",
        "",
        0,
        false,
        uid: "",
        receiverOverride: peerId);
    _sendMessageData(message, peerId: peerId, sink: sink);
  }

  Future<void> refreshConnectionLiveness() async {
    await _heartBeat();
  }

  Future<void> broadcastLocalProfileUpdate() async {
    if (connectedPeerIds.isEmpty) {
      await _heartBeat();
      return;
    }
    for (final peerId in connectedPeerIds) {
      await _heartBeat(peerId: peerId);
    }
  }

  void sendAudioControl(AudioControlMessage control) {
    sendAudioControlTo(receiver, control);
  }

  void sendAudioControlTo(String peerId, AudioControlMessage control) {
    final message = _buildMessage(
      MessageEnum.AudioControl,
      jsonEncode(control.toJson()),
      "",
      "",
      0,
      false,
      uid: control.sessionId,
      receiverOverride: peerId,
    );
    _sendMessageData(message, peerId: peerId);
  }

  void sendAudioGroupControl(AudioGroupControlMessage control) {
    sendAudioGroupControlTo(receiver, control);
  }

  void sendAudioGroupControlTo(
    String peerId,
    AudioGroupControlMessage control,
  ) {
    final message = _buildMessage(
      MessageEnum.AudioGroupControl,
      jsonEncode(control.toJson()),
      "",
      "",
      0,
      false,
      uid: control.sessionId,
      receiverOverride: peerId,
    );
    _sendMessageData(message, peerId: peerId);
  }

  void sendRemoteInputControl(RemoteInputControlMessage control) {
    sendRemoteInputControlTo(receiver, control);
  }

  void sendRemoteInputControlTo(
    String peerId,
    RemoteInputControlMessage control,
  ) {
    _remoteInputTrace(
      'remote input send control ${_remoteInputControlSummary(control)} '
      'sender=$sender receiver=$peerId connected=$isConnected '
      'remoteSupports=$supportsRemoteInput',
    );
    final message = _buildMessage(
      MessageEnum.RemoteInputControl,
      jsonEncode(control.toJson()),
      "",
      "",
      0,
      false,
      uid: control.sessionId,
      receiverOverride: peerId,
    );
    _sendMessageData(message, peerId: peerId);
  }

  Future<void> sendMessage(String content, {clipboard = false}) async {
    await sendMessageTo(receiver, content, clipboard: clipboard);
  }

  Future<void> sendMessageTo(
    String peerId,
    String content, {
    bool clipboard = false,
  }) async {
    final canUseLegacySink = peerId == receiver && _sink != null;
    if (peerId.isEmpty || (!isConnectedTo(peerId) && !canUseLegacySink)) {
      return;
    }
    if (clipboard && content.isEmpty) {
      var str = await readClipboardTextForSync() ?? "";
      content = str.trimRight();
    }
    if (content.trim().isEmpty) {
      return;
    }
    var message = _buildMessage(
      MessageEnum.Text,
      content,
      "",
      "",
      0,
      clipboard,
      receiverOverride: peerId,
    );
    await LocalDatabase().insertMessage(message);
    logger.i("创建新消息, uuid: ${message.uuid}");
    _sendMessageData(message, peerId: peerId);
  }

  Future<void> sendNotification(
      String? package, String? title, String? text) async {
    if (_sink == null || package == null && title == null && text == null) {
      return;
    }
    var content = {
      "app": await appName(package),
      "package": package,
      "title": title,
      "text": text,
    };

    var message = _buildMessage(
        MessageEnum.Notification, jsonEncode(content), "", "", 0, false);
    _send(encodeWireMessage(message));
  }

  Future<bool> sendFile(String path) async {
    return sendFileTo(receiver, path);
  }

  Future<bool> sendFileTo(String peerId, String path) =>
      _transferEngine.sendFileTo(peerId, path);

  Future<bool> sendPickedFileTo(String peerId, PickedTransferFile item) =>
      _transferEngine.sendPickedFileTo(peerId, item);

  Future<void> retryTransfer(String transferId) =>
      _transferEngine.retryTransfer(transferId);

  Future<void> cancelTransfer(String transferId) =>
      _transferEngine.cancelTransfer(transferId);
}
