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
import 'package:synchronized/synchronized.dart';
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
import 'package:whisper/socket/dial_tiebreaker.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/file_transfer_source.dart';
import 'package:whisper/socket/guarded_auth_callback.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/peer_transfer_runtime.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/state/connection_coordinator.dart';
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

  void onAuth(DeviceData? deviceData, bool asServer, String msg, var callback);

  void afterAuth(bool allow, DeviceData? device);
}

class WsSvrManager {
  static const Duration _serverPingInterval = Duration(seconds: 45);
  static const Duration _clientHeartbeatInterval = Duration(seconds: 15);

  /// 入站连接请求等待用户确认的上限;超时按拒绝处理,避免半开状态无限挂起。
  static const Duration incomingAuthRequestTimeout = Duration(minutes: 2);
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
  final AuthRequestGate _authRequestGate = AuthRequestGate();
  final Map<WebSocketSink, String> _outgoingAuthKeysBySink =
      <WebSocketSink, String>{};
  final Map<WebSocketSink, String> _incomingAuthPeerIdsBySink =
      <WebSocketSink, String>{};
  final Map<String, PeerProfile> _remoteProfilesByPeerId =
      <String, PeerProfile>{};
  final Map<WebSocketSink, Timer> _clientTimersBySink =
      <WebSocketSink, Timer>{};
  final Set<ISocketEvent> _listeners = <ISocketEvent>{};
  ISocketEvent? _primaryEvent;
  bool started = false;
  bool asServer = true;
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
    localUid: () => sender,
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

  bool _supportsFileTransferV3For(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.capabilities.fileTransferV3 == true;
  }

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
    return _selectedRemoteProfile?.trustsPeer(peerId) ?? false;
  }

  bool remotePeerTrustsPeer(String remotePeerId, String trustedPeerId) {
    final profile = _remoteProfilesByPeerId[remotePeerId] ??
        (remotePeerId == receiver ? _remoteProfile : null);
    return profile?.trustsPeer(trustedPeerId) ?? false;
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
      unawaited(ConnectionRequestNotifier().dismissForPeer(
        peerId,
        graceMillis: 3000,
      ));
    }
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
    PeerProfile? profile,
  }) async {
    if (peerId.isEmpty) {
      return;
    }
    _peerIdsBySink[sink] = peerId;
    await _peerConnections.register(
      PeerConnection(
        peerId: peerId,
        send: sink.add,
        close: () async {
          _peerIdsBySink.remove(sink);
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
    _releaseOutgoingAuthForSink(sink);
    _releaseIncomingAuthForSink(sink);
    _clientTimersBySink.remove(sink)?.cancel();
    final peerId = _peerIdsBySink.remove(sink);
    if (peerId == null) {
      if (identical(_sink, sink)) {
        _sink = null;
      }
      return;
    }
    await _peerConnections.disconnect(peerId);
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

  void startServer(int port, var callback) {
    close(closeServer: true);
    AudioShareManager.shared.onGroupPacket = (packet) {
      unawaited(AudioGroupCoordinator.shared.handlePacket(packet));
    };
    final chatHandler = webSocketHandler((WebSocketChannel webSocket) async {
      asServer = true;
      // 鉴权前不写全局 _sink:默认发送目标只能指向已鉴权 peer,
      // 由鉴权成功后的 _registerPeerConnection 统一设置。
      webSocket.stream.listen((message) {
        unawaited(_handleIncomingMessage(message, sink: webSocket.sink));
      }, onError: (Object error, StackTrace stackTrace) {
        logger.i("连接服务异常: $error\n$stackTrace");
        _dispatchToPrimary((event) => event.onError(error.toString()));
      }, onDone: () {
        logger.i("连接服务done");
        unawaited(_handlePeerSocketDoneQueued(webSocket.sink));
      });
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
      asServer = false;
      // 鉴权前不写全局 _sink,握手全程走显式 sink 参数。
      _outgoingAuthKeysBySink[channelSink] = authRequestKey;
      await _auth(true, sink: channelSink);
      connectedChannel.stream.listen((message) {
        unawaited(_handleIncomingMessage(message, sink: channelSink));
      }, onError: (error, stackTrace) {
        logger.i("客户端服务异常: $error\n$stackTrace");
        _dispatchToPrimary((event) => event.onError(error.toString()));
      }, onDone: () {
        logger.i("客户端服务done");
        unawaited(_handlePeerSocketDoneQueued(channelSink));
      });
      // 开启一个定时器，每秒执行一次
      final timer = Timer.periodic(_clientHeartbeatInterval, (timer) {
        // 在这里执行你想要重复执行的代码
        unawaited(_heartBeat(sink: channelSink));
      });
      _clientTimersBySink[channelSink] = timer;
      _clientTimer = timer;
      callback(true, "");
    } on Exception catch (e1) {
      if (channel != null) {
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
    _authRequestGate.clear();
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
  }) {
    final payload = WhisperFrameV3(
      type: WhisperFrameType.message,
      transferId: '',
      offset: 0,
      sequence: 0,
      payload: Uint8List.fromList(utf8.encode(encodeWireMessage(message))),
    ).encode();
    if (sink != null) {
      sink.add(payload);
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
      _sink?.add(bytes);
      return _sink != null;
    }
    return false;
  }

  void _send(String message) {
    final payload = _messageFrame(Uint8List.fromList(utf8.encode(message)));
    if (!_sendTo(receiver, payload)) {
      _sink?.add(payload);
    }
  }

  Future<void> _handleIncomingMessage(
    dynamic message, {
    WebSocketSink? sink,
  }) {
    _receiveQueue = _receiveQueue.then((_) async {
      try {
        await _listen(_incomingBytes(message), sink: sink);
      } catch (error, stackTrace) {
        logger.i('处理 websocket 消息失败: $error\n$stackTrace');
        _dispatchToPrimary((event) => event.onError(error.toString()));
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

  Future<void> _handleWhisperFrameV3(
    WhisperFrameV3 frame, {
    WebSocketSink? sink,
  }) async {
    switch (frame.type) {
      case WhisperFrameType.message:
        await _listen(frame.payload, sink: sink, allowFrame: false);
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
  }) async {
    if (allowFrame && WhisperFrameV3.looksLikeFrame(data)) {
      await _handleWhisperFrameV3(WhisperFrameV3.decode(data), sink: sink);
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

    switch (message.type) {
      case MessageEnum.Auth:
        {
          DeviceData? device;
          PeerProfile? profile;
          if (message.content != null) {
            profile = PeerProfile.fromJson(
              jsonDecode(message.content ?? "{}") as Map<String, dynamic>,
            );
            device = profile.device;
          }
          final peerId = device?.uid ?? incomingPeerId ?? '';
          if (!asServer) {
            _releaseOutgoingAuthForSink(sink);
          }
          _remoteInputTrace(
            'AUTH remote profile uid=${device?.uid ?? ''} '
            'protocol=${profile?.protocolVersion ?? 1} '
            'remoteInputSource=${profile?.capabilities.remoteInputSourceV1 ?? false} '
            'remoteInputSink=${profile?.capabilities.remoteInputSinkV1 ?? false} '
            'trustedPeers=${profile?.trustedPeerIds.length ?? 0}',
          );
          logger.i("AUTH message: ${message.sender} + $sender");
          // 互拨裁决:双方同时向对方拨号时,按 uid 字典序确定唯一存活连接,
          // 防止 last-writer-wins 误杀承载传输的连接。
          if (asServer && peerId.isNotEmpty) {
            final outgoingKey =
                _authRequestKey(peerId: peerId, host: '', port: 0);
            if (_authRequestGate.hasOutgoing(outgoingKey)) {
              final decision = resolveSimultaneousDial(
                localUid: sender,
                remoteUid: peerId,
              );
              if (decision == SimultaneousDialDecision.keepOutgoing) {
                logger.i('互拨裁决: 保留本机出站拨号,关闭来自 $peerId 的入站');
                await sink?.close();
                return;
              }
              logger.i('互拨裁决: 让步接受来自 $peerId 的入站,在途出站将被对端关闭');
            }
          }
          if (asServer) {
            var localTemp =
                await LocalDatabase().fetchDevice(device?.uid ?? "");
            var self = await LocalSetting().instance();
            if ((self.auth || localTemp != null && localTemp.auth)) {
              await _auth(true, sink: sink, peerId: peerId);
              receiver = peerId;
              if (peerId.isNotEmpty && sink != null) {
                await _registerPeerConnection(
                  peerId: peerId,
                  sink: sink,
                  profile: profile,
                );
              }
              _setRemoteProfile(profile, peerId: peerId);
              _dispatchToAll((event) => event.onConnect());
              unawaited(_transferEngine.resumeRecoverableOutgoing());
              _dispatchToAll((event) => event.afterAuth(true, device));
              return;
            }
          }

          if (asServer && peerId.isNotEmpty) {
            if (!_authRequestGate.tryClaimIncoming(peerId)) {
              logger.i("忽略重复连接请求: $peerId");
              await sink?.close();
              return;
            }
            if (sink != null) {
              _incomingAuthPeerIdsBySink[sink] = peerId;
            }
          }

          logger.i("AUTH message: ${message.sender} - $sender");
          Future<void> respond(bool allow) async {
            try {
              logger.i("AUTH message: ${message.message} ||| $allow");
              if (asServer) {
                await _auth(allow, sink: sink, peerId: peerId);
              }
              if (allow) {
                receiver = peerId;
                if (peerId.isNotEmpty && sink != null) {
                  await _registerPeerConnection(
                    peerId: peerId,
                    sink: sink,
                    profile: profile,
                  );
                }
                _setRemoteProfile(profile, peerId: peerId);
                _dispatchToAll((event) => event.onConnect());
                unawaited(_transferEngine.resumeRecoverableOutgoing());
              } else {
                // 拒绝只关闭这条未鉴权 socket,不得全局 close 断开其他已连 peer。
                await sink?.close();
              }
              _dispatchToAll((listener) => listener.afterAuth(allow, device));
            } finally {
              if (asServer && peerId.isNotEmpty) {
                _authRequestGate.releaseIncoming(peerId);
                if (sink != null) {
                  _incomingAuthPeerIdsBySink.remove(sink);
                }
              }
            }
          }

          Timer? incomingAuthTimer;
          final guarded = GuardedAuthCallback(
            (allow) => unawaited(respond(allow)),
            onResolved: (_) {
              incomingAuthTimer?.cancel();
              if (asServer && peerId.isNotEmpty) {
                unawaited(ConnectionRequestNotifier().dismissForPeer(peerId));
              }
            },
          );
          if (asServer &&
              peerId.isNotEmpty &&
              (message.message ?? '').isEmpty) {
            // 等待用户确认的请求超时自动拒绝;GuardedAuthCallback 幂等,
            // 用户已处理时超时回调无效果。
            incomingAuthTimer = Timer(incomingAuthRequestTimeout, () {
              logger.i('连接请求超时自动拒绝: $peerId');
              guarded.call(false);
            });
            unawaited(ConnectionRequestNotifier().maybeShowForAuthRequest(
              peerId: peerId,
              deviceName: device?.name ?? '',
              host: device?.host ?? '',
              callback: guarded,
            ));
          }
          _dispatchToPrimary((event) {
            event.onAuth(device, asServer, message.message ?? "", guarded.call);
          });
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
          final isMutuallyTrusted = storedRemote?.auth == true &&
              (remoteProfile?.trustsPeer(self.uid) ?? false);
          final localCanInject = supportsNativeRemoteInput();
          _remoteInputTrace(
            'remote input recv control ${_remoteInputControlSummary(control)} '
            'local=${self.uid} '
            'remote=${remoteDevice?.uid ?? ''} '
            'remoteAddress=${remoteDevice?.host ?? ''}:${remoteDevice?.port ?? 0} '
            'storedAuth=${storedRemote?.auth == true} '
            'remoteTrustsLocal=${remoteProfile?.trustsPeer(self.uid) ?? false} '
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
      String? receiverOverride}) {
    return MessageData(
        id: 0,
        sender: sender,
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

  Future<void> _auth(bool allow, {WebSocketSink? sink, String? peerId}) async {
    final profile = await _localPeerProfile();
    final device = profile.device;
    final topology = profile.displayTopology;
    final topologyCount = topology?.displays.length ?? 0;
    _remoteInputTrace(
      'AUTH local capabilities uid=${device.uid} '
      'protocol=${profile.protocolVersion} '
      'remoteInputSource=${profile.capabilities.remoteInputSourceV1} '
      'remoteInputSink=${profile.capabilities.remoteInputSinkV1} '
      'remoteInputTopology=${profile.capabilities.remoteInputTopologyV1} '
      'displays=$topologyCount '
      'display=${Platform.environment['DISPLAY'] ?? ''}',
    );
    var message = _buildMessage(MessageEnum.Auth, profile.toJsonString(),
        allow ? "" : "拒绝连接", "", 0, false,
        receiverOverride: peerId);
    _sendMessageData(message, peerId: peerId, sink: sink);
  }

  Future<PeerProfile> _localPeerProfile() async {
    var device = await LocalSetting().instance(online: true);
    final trustedPeerIds = await LocalDatabase().fetchTrustedPeerIds();
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
      trustedPeerIds: trustedPeerIds,
      autoApproveNewDevices: await LocalSetting().autoApproveNewDevices(),
      autoConnectEnabled: await LocalSetting().autoConnectEnabled(),
      protocolVersion: 4,
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
      final profile = PeerProfile.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
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
