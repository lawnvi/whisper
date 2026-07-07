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
import 'package:whisper/state/resumable_transfer_window.dart';
import 'package:path/path.dart' as p;

import '../helper/file.dart';
import '../helper/notification.dart';

abstract class ISocketEvent {
  void onError(String message);

  void onNotice(String message);

  void onMessage(MessageData messageData);

  void onProgress(int size, length);

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
  static const int defaultTransferChunkSize = 32 * 1024 * 1024;
  static const int transferFramePayloadSize = 4 * 1024 * 1024;
  static const int transferRawFramePayloadSize = 64 * 1024;
  static const String defaultTransferChecksumAlgorithm = 'none';
  static const int _transferChunkSize = defaultTransferChunkSize;
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
  final int _bufferSize = 16 * 1024 * 1024;
  final int oneMb = 1024 * 1024;
  bool started = false;
  bool asServer = true;
  String receiver = "";
  String sender = "";
  final _sendFileLock = Lock();
  Future<void> _receiveQueue = Future<void>.value();
  Timer? _clientTimer;
  PeerProfile? _remoteProfile;
  int _remoteProfileRevision = 0;
  final List<Completer<PeerProfile?>> _remoteProfileRefreshWaiters =
      <Completer<PeerProfile?>>[];
  final MultiPeerTransferRuntime _transferRuntime = MultiPeerTransferRuntime();
  final Map<String, IOSink> _receivingTransferSinks = <String, IOSink>{};
  final Map<String, RandomAccessFile> _receivingTransferWritersV3 =
      <String, RandomAccessFile>{};
  final Map<String, FileTransferData> _receivingTransfers =
      <String, FileTransferData>{};
  final Map<String, StreamingChecksum> _receivingChecksums =
      <String, StreamingChecksum>{};
  final Map<String, int> _receivingTransferOffsets = <String, int>{};
  final Map<String, int> _incomingBytesSinceProgress = <String, int>{};
  final Map<String, int> _incomingFramesSinceProgress = <String, int>{};
  final Map<String, int> _incomingWindowStartedAt = <String, int>{};
  final Map<String, int> _outgoingWindowSentAt = <String, int>{};
  final Map<String, int> _outgoingTransferSequences = <String, int>{};
  final Map<String, int> _incomingWindowEndOffsets = <String, int>{};
  final Map<String, int> _outgoingWindowEndOffsets = <String, int>{};
  final Map<String, TransferChunkFrame> _pendingIncomingChunkHeadersByPeer =
      <String, TransferChunkFrame>{};
  final Map<String, int> _pendingIncomingRawOffsetsByPeer = <String, int>{};
  final Map<String, int> _pendingIncomingRawRemainingByPeer = <String, int>{};

  PeerProfile? get _selectedRemoteProfile =>
      _remoteProfilesByPeerId[receiver] ?? _remoteProfile;

  Set<String> get connectedPeerIds => _peerConnections.connectedPeerIds;
  bool get isConnected =>
      _sink != null || _peerConnections.connectedPeerIds.isNotEmpty;
  bool get supportsResumableTransfer => _supportsResumableTransfer;
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
  bool get _supportsResumableTransfer =>
      _selectedRemoteProfile?.capabilities.fileResumeV1 == true;

  bool _supportsResumableTransferFor(String peerId) {
    final profile = _remoteProfilesByPeerId[peerId] ??
        (peerId == receiver ? _remoteProfile : null);
    return profile?.capabilities.fileResumeV1 == true;
  }

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

  static bool shouldUseTransferChecksum(
      String algorithm, String checksumValue) {
    final normalized = algorithm.toLowerCase();
    return normalized.isNotEmpty &&
        normalized != defaultTransferChecksumAlgorithm &&
        checksumValue.isNotEmpty;
  }

  bool _shouldStreamChecksum(String algorithm, String checksumValue) {
    return shouldUseTransferChecksum(algorithm, checksumValue);
  }

  bool _hasExpectedChecksum(String algorithm, String value) {
    return shouldUseTransferChecksum(algorithm, value);
  }

  String _formatTransferRate(int bytes, int elapsedMicros) {
    if (elapsedMicros <= 0 || bytes <= 0) {
      return 'n/a';
    }
    final seconds = elapsedMicros / Duration.microsecondsPerSecond;
    final mibPerSecond = bytes / (1024 * 1024) / seconds;
    return '${mibPerSecond.toStringAsFixed(1)}MiB/s';
  }

  void _clearIncomingTransferPerf(String transferId) {
    _incomingBytesSinceProgress.remove(transferId);
    _incomingFramesSinceProgress.remove(transferId);
    _incomingWindowStartedAt.remove(transferId);
    _incomingWindowEndOffsets.remove(transferId);
  }

  void _clearPendingIncomingChunk(String transferId) {
    final keys = _pendingIncomingChunkHeadersByPeer.entries
        .where((entry) => entry.value.transferId == transferId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in keys) {
      _pendingIncomingChunkHeadersByPeer.remove(key);
      _pendingIncomingRawOffsetsByPeer.remove(key);
      _pendingIncomingRawRemainingByPeer.remove(key);
    }
  }

  String? _peerIdForSink(WebSocketSink? sink) {
    return sink == null ? null : _peerIdsBySink[sink];
  }

  String _streamPeerKey(WebSocketSink? sink) {
    final peerId = _peerIdForSink(sink);
    if (peerId != null && peerId.isNotEmpty) {
      return peerId;
    }
    if (receiver.isNotEmpty) {
      return receiver;
    }
    return '_legacy';
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

  void _dispatchTransferData(FileTransferData data) {
    final snapshot = LocalDatabase().snapshotForTransfer(data);
    _dispatchToAll((event) => event.onTransferUpdated(snapshot));
  }

  Future<FileTransferData?> _emitTransferById(String transferId) async {
    final data = await LocalDatabase().fetchFileTransfer(transferId);
    if (data != null) {
      _dispatchTransferData(data);
    }
    return data;
  }

  Future<FileTransferData> _persistTransfer(FileTransferData data) async {
    await LocalDatabase().upsertFileTransfer(data);
    _dispatchTransferData(data);
    return data;
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

  Future<FileTransferData?> _updateTransfer(
    String transferId, {
    FileTransferState? state,
    int? committedBytes,
    String? lastError,
    String? finalPath,
    String? tempPath,
    String? checksumValue,
  }) async {
    await LocalDatabase().updateFileTransfer(
      transferId,
      state: state == null ? const Value.absent() : Value(state),
      committedBytes:
          committedBytes == null ? const Value.absent() : Value(committedBytes),
      lastError: lastError == null ? const Value.absent() : Value(lastError),
      finalPath: finalPath == null ? const Value.absent() : Value(finalPath),
      tempPath: tempPath == null ? const Value.absent() : Value(tempPath),
      checksumValue:
          checksumValue == null ? const Value.absent() : Value(checksumValue),
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
    );
    return _emitTransferById(transferId);
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
        _receivingTransferSinks.isNotEmpty ||
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
    unawaited(_markRecoverableTransfersWaitingReconnect());
    final closeResumableHandles = _closeResumableHandles();
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
    await closeResumableHandles;
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
    await _markPeerTransfersWaitingReconnect(peerId);
    // 分帧接收缓存按 peerId 索引,断开必须清理,
    // 否则同 peer 重连后的首批数据会被误当作上次未收完的原始分片。
    _pendingIncomingChunkHeadersByPeer.remove(peerId);
    _pendingIncomingRawOffsetsByPeer.remove(peerId);
    _pendingIncomingRawRemainingByPeer.remove(peerId);
    _transferRuntime.clearPeer(peerId);
    await RemoteInputWorkspaceCoordinator.shared.handlePeerDisconnected(peerId);
    if (RemoteInputCoordinator.shared.state.isForPeer(peerId)) {
      await RemoteInputCoordinator.shared.stopLocal();
    }
  }

  Future<void> _markPeerTransfersWaitingReconnect(String peerId) async {
    final items = await LocalDatabase().fetchRecoverableFileTransfersForPeer(
      peerId,
    );
    for (final item in items) {
      if (isTerminalFileTransferState(item.state)) {
        continue;
      }
      if (item.direction == FileTransferDirection.incoming) {
        await _clearActiveIncomingTransfer(
          item.transferId,
          flush: true,
          releaseRuntime: false,
        );
      }
      _outgoingWindowSentAt.remove(item.transferId);
      _outgoingWindowEndOffsets.remove(item.transferId);
      _outgoingTransferSequences.remove(item.transferId);
      await _updateTransfer(
        item.transferId,
        state: FileTransferState.waitingReconnect,
        lastError: '',
      );
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
        final message = decodeWireMessage(
          jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>,
        );
        await _handleFileTransferV3Offer(message);
        break;
      case WhisperFrameType.fileData:
        try {
          await _handleFileTransferV3Data(frame);
        } catch (error, stackTrace) {
          await _handleIncomingFileTransferV3Error(
            frame.transferId,
            error,
            stackTrace,
          );
        }
        break;
      case WhisperFrameType.fileReady:
      case WhisperFrameType.fileAck:
      case WhisperFrameType.fileComplete:
      case WhisperFrameType.fileCancel:
      case WhisperFrameType.fileError:
        final control = FileTransferV3Control.fromJson(
          jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>,
        );
        try {
          await _handleFileTransferV3Control(control);
        } catch (error, stackTrace) {
          await _handleOutgoingFileTransferV3Error(
            control.transferId,
            error,
            stackTrace,
          );
        }
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
    final streamPeerKey = _streamPeerKey(sink);
    final supportsResumableTransferForStream = streamPeerId == null
        ? _supportsResumableTransfer
        : _supportsResumableTransferFor(streamPeerId);
    final pendingHeader = _pendingIncomingChunkHeadersByPeer[streamPeerKey];
    final pendingRawRemaining =
        _pendingIncomingRawRemainingByPeer[streamPeerKey] ?? 0;
    if (supportsResumableTransferForStream &&
        pendingHeader != null &&
        pendingRawRemaining > 0) {
      final offset = _pendingIncomingRawOffsetsByPeer[streamPeerKey] ?? 0;
      if (data.length > pendingRawRemaining) {
        await _recoverIncomingTransferChunk(
          transferId: pendingHeader.transferId,
          reason:
              'raw payload length mismatch remaining=$pendingRawRemaining actual=${data.length}',
        );
        return;
      }
      final nextRemaining = pendingRawRemaining - data.length;
      _pendingIncomingRawOffsetsByPeer[streamPeerKey] = offset + data.length;
      _pendingIncomingRawRemainingByPeer[streamPeerKey] = nextRemaining;
      if (nextRemaining == 0) {
        _pendingIncomingChunkHeadersByPeer.remove(streamPeerKey);
        _pendingIncomingRawOffsetsByPeer.remove(streamPeerKey);
        _pendingIncomingRawRemainingByPeer.remove(streamPeerKey);
      }
      await _handleTransferChunk(
        TransferChunkFrame(
          transferId: pendingHeader.transferId,
          offset: offset,
          payload: data,
          payloadLength: data.length,
        ),
      );
      return;
    }

    if (supportsResumableTransferForStream &&
        TransferChunkFrame.looksLikeFrame(data)) {
      final frame = TransferChunkFrame.decode(data);
      if (frame.payloadInNextFrame) {
        if (frame.payloadLength <= 0) {
          await _recoverIncomingTransferChunk(
            transferId: frame.transferId,
            reason: 'invalid raw payload length=${frame.payloadLength}',
          );
          return;
        }
        _pendingIncomingChunkHeadersByPeer[streamPeerKey] = frame;
        _pendingIncomingRawOffsetsByPeer[streamPeerKey] = frame.offset;
        _pendingIncomingRawRemainingByPeer[streamPeerKey] = frame.payloadLength;
        _incomingWindowEndOffsets[frame.transferId] =
            frame.offset + frame.payloadLength;
        return;
      }
      await _handleTransferChunk(frame);
      return;
    }

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
              unawaited(_resumeRecoverableOutgoingTransfers());
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
                unawaited(_resumeRecoverableOutgoingTransfers());
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
        {
          if (_supportsResumableTransfer) {
            await _handleResumableFileMsg(message);
            break;
          }
          break;
        }
      case MessageEnum.TransferControl:
        {
          await _handleTransferControl(message);
          break;
        }
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
          if (_supportsResumableTransfer &&
              TransferChunkFrame.looksLikeFrame(data)) {
            await _handleTransferChunk(TransferChunkFrame.decode(data));
            return;
          }
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
        fileResumeV1: true,
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

  Future<void> retryTransfer(String transferId) async {
    final transfer = await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null) {
      return;
    }
    if (transfer.state == FileTransferState.canceled ||
        transfer.state == FileTransferState.completed) {
      return;
    }
    if (!_supportsFileTransferV3For(transfer.peerUid) ||
        !isConnectedTo(transfer.peerUid)) {
      await _updateTransfer(
        transferId,
        state: FileTransferState.waitingReconnect,
        lastError: '',
      );
      return;
    }
    if (transfer.direction == FileTransferDirection.outgoing) {
      final message =
          await LocalDatabase().fetchMessageByUuid(transfer.messageUuid);
      if (message != null) {
        _sendFileTransferV3OfferTo(transfer.peerUid, message);
      }
      await _updateTransfer(
        transferId,
        state: FileTransferState.negotiating,
        lastError: '',
      );
      return;
    }
    await _updateTransfer(
      transferId,
      state: FileTransferState.negotiating,
      lastError: '',
    );
    await _sendFileTransferV3Ready(transferId);
  }

  Future<void> cancelTransfer(String transferId) async {
    final transfer = await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null) {
      return;
    }
    await _updateTransfer(
      transferId,
      state: FileTransferState.canceled,
      lastError: '',
    );
    if (_supportsFileTransferV3For(transfer.peerUid) &&
        isConnectedTo(transfer.peerUid)) {
      _sendFileTransferV3ControlTo(
        transfer.peerUid,
        FileTransferV3Control(
          action: FileTransferV3Action.cancel,
          transferId: transfer.transferId,
          durableOffset: transfer.committedBytes,
          size: transfer.size,
          errorCode: '',
          errorMessage: '',
        ),
      );
    }
    if (_transferRuntime.activeIncomingFor(transfer.peerUid) == transferId) {
      await _clearActiveIncomingTransfer(transferId, flush: true);
      await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
    }
    if (_transferRuntime.activeOutgoingFor(transfer.peerUid) == transferId) {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingWindowSentAt.remove(transferId);
    _outgoingWindowEndOffsets.remove(transferId);
    _outgoingTransferSequences.remove(transferId);
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

  Future<bool> sendPickedFileTo(String peerId, PickedTransferFile item) async {
    if (item.isAndroidContentUri) {
      return sendAndroidContentUriTo(
        peerId,
        uri: item.androidContentUri!,
        name: item.name,
        size: item.size,
        fileTimestamp: item.lastModified,
      );
    }
    final path = item.path;
    if (path == null || path.isEmpty) {
      return false;
    }
    return sendFileTo(peerId, path);
  }

  Future<bool> sendFileTo(String peerId, String path) async {
    return _sendFileLock.synchronized(() async {
      final canUseLegacySink = peerId == receiver && _sink != null;
      if (peerId.isEmpty || (!isConnectedTo(peerId) && !canUseLegacySink)) {
        return false;
      }
      if (!_supportsFileTransferV3For(peerId)) {
        _dispatchToAll((event) => event.onNotice('当前设备版本不支持新版文件传输'));
        return false;
      }
      final file = File(path);
      if (!file.existsSync() ||
          FileSystemEntity.typeSync(path) == FileSystemEntityType.directory) {
        return false;
      }
      final size = file.lengthSync();
      final timestamp = (await file.lastModified()).millisecondsSinceEpoch;
      final fileName = p.basename(path);
      final now = DateTime.now().millisecondsSinceEpoch;
      const checksumAlgorithm = defaultTransferChecksumAlgorithm;
      const checksumValue = '';
      final content = jsonEncode(
        _FileTransferMetadata(
          checksumAlgorithm: checksumAlgorithm,
          checksumValue: checksumValue,
          chunkSize: fileTransferV3WindowSize,
          protocolVersion: fileTransferV3ProtocolVersion,
        ).toJson(),
      );
      var message = _buildMessage(
          MessageEnum.File, content, "", fileName, size, false,
          path: path,
          md5: '',
          fileTimestamp: timestamp,
          receiverOverride: peerId);
      await LocalDatabase().insertMessage(message);
      final metadata = _FileTransferMetadata.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
      logger.i(
        'file transfer v3 offer transfer=${message.uuid} size=$size path=$path',
      );
      await _persistTransfer(
        FileTransferData(
          transferId: message.uuid,
          messageUuid: message.uuid,
          peerUid: peerId,
          direction: FileTransferDirection.outgoing,
          state: FileTransferState.queued,
          finalPath: path,
          tempPath: '',
          size: size,
          checksumAlgorithm: metadata.checksumAlgorithm,
          checksumValue: metadata.checksumValue,
          chunkSize: metadata.chunkSize,
          committedBytes: 0,
          lastError: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
      _dispatchOutgoingMessage(message);
      _sendFileTransferV3OfferTo(peerId, message);
      return true;
    });
  }

  Future<bool> sendAndroidContentUriTo(
    String peerId, {
    required String uri,
    required String name,
    required int size,
    required int fileTimestamp,
  }) async {
    return _sendFileLock.synchronized(() async {
      final canUseLegacySink = peerId == receiver && _sink != null;
      if (peerId.isEmpty || (!isConnectedTo(peerId) && !canUseLegacySink)) {
        return false;
      }
      if (uri.isEmpty || !isAndroidContentUri(uri)) {
        return false;
      }
      if (!_supportsFileTransferV3For(peerId)) {
        _dispatchToAll((event) => event.onNotice('当前设备版本不支持无复制文件发送'));
        return false;
      }

      const checksumAlgorithm = defaultTransferChecksumAlgorithm;
      const checksumValue = '';
      final now = DateTime.now().millisecondsSinceEpoch;
      final content = jsonEncode(
        _FileTransferMetadata(
          checksumAlgorithm: checksumAlgorithm,
          checksumValue: checksumValue,
          chunkSize: fileTransferV3WindowSize,
          protocolVersion: fileTransferV3ProtocolVersion,
        ).toJson(),
      );
      final fileName = name.isNotEmpty ? name : 'document';
      final message = _buildMessage(
        MessageEnum.File,
        content,
        '',
        fileName,
        size,
        false,
        path: uri,
        md5: '',
        fileTimestamp: fileTimestamp > 0 ? fileTimestamp : now,
        receiverOverride: peerId,
      );
      await LocalDatabase().insertMessage(message);
      final metadata = _FileTransferMetadata.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
      logger.i(
        'resumable send android uri transfer=${message.uuid} size=$size '
        'checksum=$content uri=$uri',
      );
      await _persistTransfer(
        FileTransferData(
          transferId: message.uuid,
          messageUuid: message.uuid,
          peerUid: peerId,
          direction: FileTransferDirection.outgoing,
          state: FileTransferState.queued,
          finalPath: uri,
          tempPath: '',
          size: size,
          checksumAlgorithm: metadata.checksumAlgorithm,
          checksumValue: metadata.checksumValue,
          chunkSize: metadata.chunkSize,
          committedBytes: 0,
          lastError: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
      _dispatchOutgoingMessage(message);
      _sendFileTransferV3OfferTo(peerId, message);
      return true;
    });
  }

  void _sendFileTransferV3OfferTo(String peerId, MessageData message) {
    _sendFileTransferV3FrameTo(
      peerId,
      WhisperFrameV3(
        type: WhisperFrameType.fileOffer,
        transferId: message.uuid,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(encodeWireMessage(message))),
      ),
    );
  }

  void _sendFileTransferV3ControlTo(
    String peerId,
    FileTransferV3Control control,
  ) {
    final type = switch (control.action) {
      FileTransferV3Action.ready => WhisperFrameType.fileReady,
      FileTransferV3Action.ack => WhisperFrameType.fileAck,
      FileTransferV3Action.complete => WhisperFrameType.fileComplete,
      FileTransferV3Action.cancel => WhisperFrameType.fileCancel,
      FileTransferV3Action.error => WhisperFrameType.fileError,
    };
    _sendFileTransferV3FrameTo(
      peerId,
      WhisperFrameV3(
        type: type,
        transferId: control.transferId,
        offset: control.durableOffset,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(control.toJson()))),
      ),
    );
  }

  bool _sendFileTransferV3FrameTo(String peerId, WhisperFrameV3 frame) {
    return _sendBytesToPeer(peerId, frame.encode());
  }

  Future<void> _handleFileTransferV3Offer(MessageData message) async {
    final metadata = _FileTransferMetadata.fromContent(message.content);
    if (metadata == null ||
        metadata.protocolVersion != fileTransferV3ProtocolVersion) {
      _sendFileTransferV3ControlTo(
        message.sender,
        FileTransferV3Control(
          action: FileTransferV3Action.error,
          transferId: message.uuid,
          durableOffset: 0,
          size: message.size,
          errorCode: 'protocol',
          errorMessage: '文件传输协议版本不支持',
        ),
      );
      return;
    }

    final db = LocalDatabase();
    var transfer = await db.fetchFileTransfer(message.uuid);
    if (transfer == null) {
      final finalPath = await allocateFinalDownloadPath(message.name);
      final tempPath = await transferTempFilePath(message.uuid);
      final availableBytes =
          await availableBytesForPath((await downloadDir()).path);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!hasEnoughStorageForFile(
        fileSize: message.size,
        availableBytes: availableBytes,
      )) {
        transfer = FileTransferData(
          transferId: message.uuid,
          messageUuid: message.uuid,
          peerUid: message.sender,
          direction: FileTransferDirection.incoming,
          state: FileTransferState.failed,
          finalPath: finalPath,
          tempPath: tempPath,
          size: message.size,
          checksumAlgorithm: metadata.checksumAlgorithm,
          checksumValue: metadata.checksumValue,
          chunkSize: metadata.chunkSize,
          committedBytes: 0,
          lastError: '接收 ${message.name} 失败：存储空间不足',
          createdAt: now,
          updatedAt: now,
        );
        await _persistTransfer(transfer);
        _sendFileTransferV3ControlTo(
          transfer.peerUid,
          FileTransferV3Control(
            action: FileTransferV3Action.error,
            transferId: transfer.transferId,
            durableOffset: 0,
            size: transfer.size,
            errorCode: 'storage',
            errorMessage: transfer.lastError,
          ),
        );
        _dispatchToAll((event) => event.onNotice(transfer!.lastError));
        return;
      }
      final decision = _transferRuntime.enqueue(
        peerId: message.sender,
        transferId: message.uuid,
        direction: FileTransferDirection.incoming,
      );
      transfer = FileTransferData(
        transferId: message.uuid,
        messageUuid: message.uuid,
        peerUid: message.sender,
        direction: FileTransferDirection.incoming,
        state: decision == TransferRuntimeDecision.started
            ? FileTransferState.negotiating
            : FileTransferState.queued,
        finalPath: finalPath,
        tempPath: tempPath,
        size: message.size,
        checksumAlgorithm: metadata.checksumAlgorithm,
        checksumValue: metadata.checksumValue,
        chunkSize: metadata.chunkSize,
        committedBytes: 0,
        lastError: '',
        createdAt: now,
        updatedAt: now,
      );
      await _persistTransfer(transfer);
    } else if (!isTerminalFileTransferState(transfer.state)) {
      _transferRuntime.enqueue(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.incoming,
      );
    }

    final existingMessage = await db.fetchMessageByUuid(message.uuid);
    if (existingMessage == null) {
      final json = message.toJson();
      json['path'] = transfer.finalPath;
      final newMessage = decodeWireMessage(json);
      await db.insertMessage(newMessage);
      _dispatchToAll((event) => event.onMessage(newMessage));
    }
    _ackMessage(message);

    if (_transferRuntime.activeIncomingFor(transfer.peerUid) ==
        transfer.transferId) {
      await _sendFileTransferV3Ready(transfer.transferId);
    }
  }

  Future<void> _sendFileTransferV3Ready(String transferId) async {
    final transfer = await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null || isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
    }
    final tempFile = File(transfer.tempPath);
    if (!tempFile.existsSync()) {
      await tempFile.parent.create(recursive: true);
      await tempFile.create(recursive: true);
    }
    var durableOffset = await tempFile.length();
    if (durableOffset > transfer.size) {
      durableOffset = 0;
      await tempFile.writeAsBytes(const <int>[], flush: true);
    }
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.negotiating,
      committedBytes: durableOffset,
      lastError: '',
    );
    _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: transfer.transferId,
        durableOffset: durableOffset,
        size: transfer.size,
        errorCode: '',
        errorMessage: '',
      ),
    );
    if (updated != null) {
      _receivingTransfers[updated.transferId] = updated;
    }
  }

  Future<void> _handleFileTransferV3Control(
    FileTransferV3Control control,
  ) async {
    switch (control.action) {
      case FileTransferV3Action.ready:
        await _handleFileTransferV3Ready(control);
        break;
      case FileTransferV3Action.ack:
        await _handleFileTransferV3Ack(control);
        break;
      case FileTransferV3Action.complete:
        await _handleFileTransferV3Complete(control);
        break;
      case FileTransferV3Action.cancel:
        await _handleFileTransferV3Cancel(control);
        break;
      case FileTransferV3Action.error:
        await _handleFileTransferV3Error(control);
        break;
    }
  }

  Future<void> _handleFileTransferV3Ready(
    FileTransferV3Control control,
  ) async {
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final message =
        await LocalDatabase().fetchMessageByUuid(transfer.messageUuid);
    if (message == null) {
      return;
    }
    final source = _transferSourceForMessage(message, transfer);
    try {
      if (!await source.exists() || await source.length() != transfer.size) {
        await _failOutgoingFileTransferV3(transfer, '源文件不存在或已变化，无法继续传输');
        return;
      }
    } catch (error, stackTrace) {
      await _handleOutgoingTransferError(transfer, error, stackTrace);
      return;
    }
    final activeOutgoing = _transferRuntime.activeOutgoingFor(transfer.peerUid);
    if (activeOutgoing != null && activeOutgoing != transfer.transferId) {
      final decision = _transferRuntime.enqueue(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.outgoing,
      );
      if (decision == TransferRuntimeDecision.queued) {
        return;
      }
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.outgoing,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
    }
    final offset = math.min(control.durableOffset, transfer.size);
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.transferring,
      committedBytes: offset,
      lastError: '',
    );
    if (updated == null) {
      return;
    }
    await _sendFileTransferV3WindowSafely(updated, message, offset: offset);
  }

  Future<void> _failOutgoingFileTransferV3(
    FileTransferData transfer,
    String message,
  ) async {
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.failed,
      lastError: message,
    );
    _transferRuntime.complete(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.outgoing,
    );
    _outgoingWindowSentAt.remove(transfer.transferId);
    _outgoingWindowEndOffsets.remove(transfer.transferId);
    _outgoingTransferSequences.remove(transfer.transferId);
    _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.error,
        transferId: transfer.transferId,
        durableOffset: transfer.committedBytes,
        size: transfer.size,
        errorCode: 'source',
        errorMessage: message,
      ),
    );
    _dispatchToAll((event) => event.onNotice(message));
  }

  Future<void> _handleOutgoingFileTransferV3Error(
    String transferId,
    Object error,
    StackTrace stackTrace,
  ) async {
    final transfer = await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final message = _outgoingFileTransferV3ErrorMessage(error);
    logger.i(
      'file transfer v3 outgoing failed transfer=$transferId '
      'peer=${transfer.peerUid} error=$error\n$stackTrace',
    );
    await _failOutgoingFileTransferV3(transfer, message);
  }

  String _outgoingFileTransferV3ErrorMessage(Object error) {
    if (error is FileSystemException) {
      final detail = error.message.isNotEmpty
          ? error.message
          : error.osError?.message ?? error.toString();
      return '发送文件失败：$detail';
    }
    return '发送文件失败：$error';
  }

  Future<void> _sendFileTransferV3WindowSafely(
    FileTransferData transfer,
    MessageData message, {
    required int offset,
  }) async {
    try {
      await _sendFileTransferV3Window(transfer, message, offset: offset);
    } catch (error, stackTrace) {
      await _handleOutgoingFileTransferV3Error(
        transfer.transferId,
        error,
        stackTrace,
      );
    }
  }

  Future<void> _sendFileTransferV3Window(
    FileTransferData transfer,
    MessageData message, {
    required int offset,
  }) async {
    if (!isConnectedTo(transfer.peerUid) && transfer.peerUid != receiver) {
      return;
    }
    if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
        transfer.transferId) {
      return;
    }
    final source = _transferSourceForMessage(message, transfer);
    final durableOffset = math.min(offset, transfer.size);
    final windowEnd =
        math.min(transfer.size, durableOffset + fileTransferV3WindowSize);
    _outgoingWindowSentAt[transfer.transferId] =
        DateTime.now().microsecondsSinceEpoch;
    var sequence = _outgoingTransferSequences[transfer.transferId] ?? 0;
    var cursor =
        _outgoingWindowEndOffsets[transfer.transferId] ?? durableOffset;
    if (cursor < durableOffset || cursor > windowEnd) {
      cursor = durableOffset;
    }
    while (cursor < windowEnd) {
      if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
          transfer.transferId) {
        return;
      }
      final length =
          math.min(fileTransferV3FramePayloadSize, windowEnd - cursor);
      final payload = await source.readRange(cursor, length);
      if (payload.length != length) {
        throw FileSystemException(
          'Unexpected EOF while reading transfer frame',
          message.path,
        );
      }
      final sent = _sendFileTransferV3FrameTo(
        transfer.peerUid,
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transfer.transferId,
          offset: cursor,
          sequence: sequence,
          payload: payload,
        ),
      );
      if (!sent) {
        return;
      }
      cursor += payload.length;
      sequence++;
      _outgoingWindowEndOffsets[transfer.transferId] = cursor;
      await _yieldAfterFileTransferFrame();
    }
    _outgoingTransferSequences[transfer.transferId] = sequence;
  }

  Future<void> _yieldAfterFileTransferFrame() {
    return Future<void>.delayed(Duration.zero);
  }

  Future<void> _handleFileTransferV3Data(WhisperFrameV3 frame) async {
    var transfer = _receivingTransfers[frame.transferId];
    transfer ??= await LocalDatabase().fetchFileTransfer(frame.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    if (_transferRuntime.activeIncomingFor(transfer.peerUid) !=
        transfer.transferId) {
      return;
    }
    final expectedOffset = _receivingTransferOffsets[transfer.transferId] ??
        transfer.committedBytes;
    if (frame.offset != expectedOffset) {
      final durableOffset = await _flushIncomingFileTransferV3(
        transfer,
        expectedOffset,
      );
      _sendFileTransferV3Ack(transfer, durableOffset);
      return;
    }

    final tempFile = File(transfer.tempPath);
    if (!tempFile.existsSync()) {
      await tempFile.parent.create(recursive: true);
      await tempFile.create(recursive: true);
    }
    var writer = _receivingTransferWritersV3[transfer.transferId];
    if (writer == null) {
      final currentLength = await tempFile.length();
      if (currentLength > frame.offset) {
        final truncatingWriter = await tempFile.open(mode: FileMode.write);
        try {
          await truncatingWriter.truncate(frame.offset);
        } finally {
          await truncatingWriter.close();
        }
      } else if (currentLength < frame.offset) {
        _sendFileTransferV3Ack(transfer, currentLength);
        return;
      }
      writer = await tempFile.open(mode: FileMode.writeOnlyAppend);
      _receivingTransferWritersV3[transfer.transferId] = writer;
      _receivingTransfers[transfer.transferId] = transfer;
      _receivingTransferOffsets[transfer.transferId] = frame.offset;
    }

    await writer.writeFrom(frame.payload);
    final committedBytes = frame.offset + frame.payload.length;
    _receivingTransferOffsets[transfer.transferId] = committedBytes;
    _dispatchTransferProgress(
      transfer,
      committedBytes: committedBytes,
      state: committedBytes >= transfer.size
          ? FileTransferState.verifying
          : FileTransferState.transferring,
    );

    if (committedBytes >= transfer.size) {
      final durableOffset = await _flushIncomingFileTransferV3(
        transfer,
        transfer.size,
      );
      final updated = await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.verifying,
        committedBytes: durableOffset,
        lastError: '',
      );
      if (updated != null) {
        await _finalizeIncomingFileTransferV3(updated);
      }
      return;
    }

    if (committedBytes - transfer.committedBytes >=
        fileTransferV3AckIntervalSize) {
      final durableOffset = await _flushIncomingFileTransferV3(
        transfer,
        committedBytes,
      );
      final updated = await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.transferring,
        committedBytes: durableOffset,
        lastError: '',
      );
      if (updated != null) {
        _receivingTransfers[updated.transferId] = updated;
        _sendFileTransferV3Ack(updated, durableOffset);
      }
    }
  }

  Future<void> _handleIncomingFileTransferV3Error(
    String transferId,
    Object error,
    StackTrace stackTrace,
  ) async {
    final transfer = _receivingTransfers[transferId] ??
        await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }

    final message = _incomingFileTransferV3ErrorMessage(error);
    final durableOffset =
        _receivingTransferOffsets[transferId] ?? transfer.committedBytes;
    logger.i(
      'file transfer v3 incoming failed transfer=$transferId '
      'peer=${transfer.peerUid} temp=${transfer.tempPath} error=$error\n$stackTrace',
    );
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.failed,
      committedBytes: math.min(durableOffset, transfer.size),
      lastError: message,
    );
    _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.error,
        transferId: transfer.transferId,
        durableOffset: math.min(durableOffset, transfer.size),
        size: transfer.size,
        errorCode: 'receiver',
        errorMessage: message,
      ),
    );
    await _clearFailedIncomingFileTransferV3(transfer);
    await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
    _dispatchToAll((event) => event.onNotice(message));
  }

  String _incomingFileTransferV3ErrorMessage(Object error) {
    if (error is FileSystemException) {
      final detail = error.message.isNotEmpty
          ? error.message
          : error.osError?.message ?? error.toString();
      return '接收文件失败：$detail';
    }
    return '接收文件失败：$error';
  }

  Future<void> _clearFailedIncomingFileTransferV3(
    FileTransferData transfer,
  ) async {
    try {
      await _closeReceivingTransferFile(transfer.transferId, flush: false);
    } catch (error, stackTrace) {
      logger.i(
        'file transfer v3 failed close ignored transfer=${transfer.transferId} '
        'error=$error\n$stackTrace',
      );
    }
    _receivingTransfers.remove(transfer.transferId);
    _receivingChecksums.remove(transfer.transferId);
    _receivingTransferOffsets.remove(transfer.transferId);
    _transferRuntime.complete(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
    _clearIncomingTransferPerf(transfer.transferId);
    _clearPendingIncomingChunk(transfer.transferId);
  }

  void _dispatchTransferProgress(
    FileTransferData transfer, {
    required int committedBytes,
    required FileTransferState state,
  }) {
    _dispatchToAll(
      (event) => event.onTransferUpdated(
        TransferSnapshot(
          transferId: transfer.transferId,
          messageUuid: transfer.messageUuid,
          peerUid: transfer.peerUid,
          direction: transfer.direction,
          state: state,
          finalPath: transfer.finalPath,
          tempPath: transfer.tempPath,
          size: transfer.size,
          committedBytes: committedBytes,
          lastError: transfer.lastError,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
  }

  Future<int> _flushIncomingFileTransferV3(
    FileTransferData transfer,
    int offset,
  ) async {
    final writer = _receivingTransferWritersV3[transfer.transferId];
    if (writer != null) {
      await writer.flush();
      return math.min(offset, transfer.size);
    }
    final sink = _receivingTransferSinks[transfer.transferId];
    if (sink != null) {
      await sink.flush();
    }
    return math.min(offset, transfer.size);
  }

  void _sendFileTransferV3Ack(
    FileTransferData transfer,
    int durableOffset,
  ) {
    _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.ack,
        transferId: transfer.transferId,
        durableOffset: durableOffset,
        size: transfer.size,
        errorCode: '',
        errorMessage: '',
      ),
    );
  }

  Future<void> _handleFileTransferV3Ack(FileTransferV3Control control) async {
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final durableOffset = math.min(control.durableOffset, transfer.size);
    if (durableOffset < transfer.committedBytes) {
      _outgoingWindowEndOffsets[control.transferId] = durableOffset;
    }
    final updated = await _updateTransfer(
      transfer.transferId,
      state: durableOffset >= transfer.size
          ? FileTransferState.verifying
          : FileTransferState.transferring,
      committedBytes: durableOffset,
      lastError: '',
    );
    if (updated == null || durableOffset >= updated.size) {
      _outgoingWindowSentAt.remove(control.transferId);
      _outgoingWindowEndOffsets.remove(control.transferId);
      return;
    }
    final message =
        await LocalDatabase().fetchMessageByUuid(updated.messageUuid);
    if (message == null) {
      return;
    }
    await _sendFileTransferV3WindowSafely(
      updated,
      message,
      offset: durableOffset,
    );
  }

  Future<void> _startQueuedOutgoingFileTransferV3(String? transferId) async {
    if (transferId == null || transferId.isEmpty) {
      return;
    }
    final transfer = await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.outgoing,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
    }
    final message =
        await LocalDatabase().fetchMessageByUuid(transfer.messageUuid);
    if (message == null) {
      return;
    }
    final offset = math.min(transfer.committedBytes, transfer.size);
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.transferring,
      committedBytes: offset,
      lastError: '',
    );
    if (updated == null) {
      return;
    }
    await _sendFileTransferV3WindowSafely(updated, message, offset: offset);
  }

  Future<void> _handleFileTransferV3Complete(
    FileTransferV3Control control,
  ) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.completed,
      committedBytes: control.size,
      lastError: '',
    );
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    String? nextTransferId;
    if (transfer != null) {
      nextTransferId = _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingWindowSentAt.remove(control.transferId);
    _outgoingWindowEndOffsets.remove(control.transferId);
    _outgoingTransferSequences.remove(control.transferId);
    await _startQueuedOutgoingFileTransferV3(nextTransferId);
  }

  Future<void> _handleFileTransferV3Cancel(
      FileTransferV3Control control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.canceled,
      lastError: control.errorMessage,
    );
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer == null) {
      return;
    }
    if (transfer.direction == FileTransferDirection.incoming) {
      await _clearActiveIncomingTransfer(transfer.transferId, flush: true);
      await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
    } else {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingTransferSequences.remove(transfer.transferId);
  }

  Future<void> _handleFileTransferV3Error(FileTransferV3Control control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.failed,
      lastError: control.errorMessage,
    );
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer != null) {
      if (transfer.direction == FileTransferDirection.incoming) {
        await _clearActiveIncomingTransfer(transfer.transferId, flush: true);
        await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
      } else {
        _transferRuntime.complete(
          peerId: transfer.peerUid,
          transferId: transfer.transferId,
          direction: FileTransferDirection.outgoing,
        );
      }
    }
    _outgoingTransferSequences.remove(control.transferId);
    if (control.errorMessage.isNotEmpty) {
      _dispatchToAll((event) => event.onNotice(control.errorMessage));
    }
  }

  Future<void> _finalizeIncomingFileTransferV3(
    FileTransferData transfer,
  ) async {
    await _closeReceivingTransferFile(transfer.transferId, flush: true);
    final tempFile = File(transfer.tempPath);
    final finalFile = File(transfer.finalPath);
    if (finalFile.existsSync()) {
      await finalFile.delete();
    }
    final message =
        await LocalDatabase().fetchMessageByUuid(transfer.messageUuid);
    if (message?.fileTimestamp != null && (message!.fileTimestamp ?? 0) > 0) {
      await tempFile.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(message.fileTimestamp!),
      );
    }
    await tempFile.rename(transfer.finalPath);
    await notifyFileVisibleToAndroidPickers(transfer.finalPath);
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.completed,
      committedBytes: transfer.size,
      lastError: '',
    );
    _sendFileTransferV3ControlTo(
      transfer.peerUid,
      FileTransferV3Control(
        action: FileTransferV3Action.complete,
        transferId: transfer.transferId,
        durableOffset: transfer.size,
        size: transfer.size,
        errorCode: '',
        errorMessage: '',
      ),
    );
    await _clearActiveIncomingTransfer(transfer.transferId, flush: false);
    await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
  }

  void _sendTransferControl(TransferControl control) {
    _sendTransferControlTo(receiver, control);
  }

  void _sendTransferControlTo(String peerId, TransferControl control) {
    final message = _buildMessage(
      MessageEnum.TransferControl,
      jsonEncode(control.toJson()),
      '',
      '',
      0,
      false,
      receiverOverride: peerId,
    );
    _sendMessageData(message, peerId: peerId);
  }

  Future<void> _handleResumableFileMsg(MessageData message) async {
    final metadata = _FileTransferMetadata.fromContent(message.content);
    if (metadata == null) {
      logger.i("忽略缺少传输元数据的文件消息: ${message.uuid}");
      return;
    }

    final db = LocalDatabase();
    var transfer = await db.fetchFileTransfer(message.uuid);
    if (transfer == null) {
      final finalPath = await allocateFinalDownloadPath(message.name);
      final tempPath = await transferTempFilePath(message.uuid);
      final availableBytes =
          await availableBytesForPath((await downloadDir()).path);
      if (!hasEnoughStorageForFile(
        fileSize: message.size,
        availableBytes: availableBytes,
      )) {
        final now = DateTime.now().millisecondsSinceEpoch;
        transfer = FileTransferData(
          transferId: message.uuid,
          messageUuid: message.uuid,
          peerUid: message.sender,
          direction: FileTransferDirection.incoming,
          state: FileTransferState.failed,
          finalPath: finalPath,
          tempPath: tempPath,
          size: message.size,
          checksumAlgorithm: metadata.checksumAlgorithm,
          checksumValue: metadata.checksumValue,
          chunkSize: metadata.chunkSize,
          committedBytes: 0,
          lastError: '接收 ${message.name} 失败：存储空间不足',
          createdAt: now,
          updatedAt: now,
        );
        await _persistTransfer(transfer);
        _sendTransferControlTo(
          transfer.peerUid,
          TransferControl(
            action: TransferAction.error,
            transferId: message.uuid,
            name: message.name,
            size: message.size,
            fileTimestamp: message.fileTimestamp ?? 0,
            checksumAlgorithm: metadata.checksumAlgorithm,
            checksumValue: metadata.checksumValue,
            chunkSize: metadata.chunkSize,
            resumeOffset: 0,
            resumeProofHash: '',
            errorCode: 'storage',
            errorMessage: transfer.lastError,
          ),
        );
        _dispatchToAll((event) => event.onNotice(transfer!.lastError));
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final runtimeDecision = _transferRuntime.enqueue(
        peerId: message.sender,
        transferId: message.uuid,
        direction: FileTransferDirection.incoming,
      );
      transfer = FileTransferData(
        transferId: message.uuid,
        messageUuid: message.uuid,
        peerUid: message.sender,
        direction: FileTransferDirection.incoming,
        state: runtimeDecision == TransferRuntimeDecision.started
            ? FileTransferState.negotiating
            : FileTransferState.queued,
        finalPath: finalPath,
        tempPath: tempPath,
        size: message.size,
        checksumAlgorithm: metadata.checksumAlgorithm,
        checksumValue: metadata.checksumValue,
        chunkSize: metadata.chunkSize,
        committedBytes: 0,
        lastError: '',
        createdAt: now,
        updatedAt: now,
      );
      await _persistTransfer(transfer);
    } else if (!isTerminalFileTransferState(transfer.state)) {
      _transferRuntime.enqueue(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.incoming,
      );
    }

    final existingMessage = await db.fetchMessageByUuid(message.uuid);
    if (existingMessage == null) {
      final json = message.toJson();
      json['path'] = transfer.finalPath;
      final newMessage = decodeWireMessage(json);
      await db.insertMessage(newMessage);
      _dispatchToAll((event) => event.onMessage(newMessage));
    }
    _ackMessage(message);

    if (_transferRuntime.activeIncomingFor(transfer.peerUid) ==
        transfer.transferId) {
      await _sendReadyForIncomingTransfer(transfer.transferId);
    }
  }

  Future<void> _handleTransferControl(MessageData message) async {
    final json = jsonDecode(message.content ?? '{}') as Map<String, dynamic>;
    final control = TransferControl.fromJson(json);
    switch (control.action) {
      case TransferAction.resumeProbe:
        await _handleResumeProbe(control);
        break;
      case TransferAction.ready:
        await _handleReady(control);
        break;
      case TransferAction.restart:
        await _handleRestart(control);
        break;
      case TransferAction.progress:
        await _handleTransferProgress(control);
        break;
      case TransferAction.complete:
        await _handleTransferComplete(control);
        break;
      case TransferAction.pause:
        await _handlePeerPause(control);
        break;
      case TransferAction.cancel:
        await _handlePeerCancel(control);
        break;
      case TransferAction.error:
        await _handlePeerError(control);
        break;
    }
  }

  Future<void> _handleResumeProbe(TransferControl control) async {
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
    }
    await _sendReadyForIncomingTransfer(transfer.transferId);
  }

  Future<void> _sendReadyForIncomingTransfer(String transferId) async {
    final transfer = await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null) {
      return;
    }
    if (isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.incoming,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
    }
    final tempFile = File(transfer.tempPath);
    if (!tempFile.existsSync()) {
      await tempFile.parent.create(recursive: true);
      await tempFile.create(recursive: true);
    }
    var resumeOffset = await tempFile.length();
    if (resumeOffset > transfer.size) {
      resumeOffset = 0;
      await tempFile.writeAsBytes(const <int>[], flush: true);
    }
    final proof = await resumeProofHash(
      tempFile,
      resumeOffset: resumeOffset,
      chunkSize: transfer.chunkSize,
    );
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.negotiating,
      committedBytes: resumeOffset,
      lastError: '',
    );
    _sendTransferControlTo(
      transfer.peerUid,
      TransferControl(
        action: TransferAction.ready,
        transferId: transfer.transferId,
        name: '',
        size: transfer.size,
        fileTimestamp: 0,
        checksumAlgorithm: transfer.checksumAlgorithm,
        checksumValue: transfer.checksumValue,
        chunkSize: transfer.chunkSize,
        resumeOffset: resumeOffset,
        resumeProofHash: proof,
        errorCode: '',
        errorMessage: '',
      ),
    );
  }

  FileTransferSource _transferSourceForMessage(
    MessageData message,
    FileTransferData transfer,
  ) {
    if (isAndroidContentUri(message.path)) {
      return AndroidContentUriTransferSource(
        uri: message.path,
        expectedSize: transfer.size,
      );
    }
    return PathFileTransferSource(message.path);
  }

  Future<void> _handleReady(TransferControl control) async {
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    final message =
        await LocalDatabase().fetchMessageByUuid(transfer.messageUuid);
    if (message == null) {
      return;
    }
    final source = _transferSourceForMessage(message, transfer);
    try {
      if (!await source.exists()) {
        await _updateTransfer(
          transfer.transferId,
          state: FileTransferState.failed,
          lastError: '源文件不存在，无法继续传输',
        );
        return;
      }
      if (await source.length() != transfer.size) {
        await _updateTransfer(
          transfer.transferId,
          state: FileTransferState.failed,
          lastError: '源文件已变化，无法继续传输',
        );
        return;
      }
      if (_hasExpectedChecksum(
        transfer.checksumAlgorithm,
        transfer.checksumValue,
      )) {
        final currentChecksum = await checksumForTransferSource(
          source,
          algorithm: transfer.checksumAlgorithm,
        );
        if (currentChecksum != transfer.checksumValue) {
          await _updateTransfer(
            transfer.transferId,
            state: FileTransferState.failed,
            lastError: '源文件已变化，无法继续传输',
          );
          return;
        }
      }
      if (control.resumeOffset > 0) {
        final proof = await resumeProofHashForTransferSource(
          source,
          resumeOffset: control.resumeOffset,
          chunkSize: transfer.chunkSize,
        );
        if (proof != control.resumeProofHash) {
          _sendTransferControlTo(
            transfer.peerUid,
            TransferControl(
              action: TransferAction.restart,
              transferId: transfer.transferId,
              name: '',
              size: transfer.size,
              fileTimestamp: message.fileTimestamp ?? 0,
              checksumAlgorithm: transfer.checksumAlgorithm,
              checksumValue: transfer.checksumValue,
              chunkSize: transfer.chunkSize,
              resumeOffset: 0,
              resumeProofHash: '',
              errorCode: '',
              errorMessage: '',
            ),
          );
          return;
        }
      }
    } catch (error, stackTrace) {
      await _handleOutgoingTransferError(transfer, error, stackTrace);
      return;
    }
    final activeOutgoing = _transferRuntime.activeOutgoingFor(transfer.peerUid);
    if (activeOutgoing != null && activeOutgoing != transfer.transferId) {
      return;
    }
    final decision = _transferRuntime.enqueue(
      peerId: transfer.peerUid,
      transferId: transfer.transferId,
      direction: FileTransferDirection.outgoing,
    );
    if (decision == TransferRuntimeDecision.queued) {
      return;
    }
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.transferring,
      committedBytes: control.resumeOffset,
      lastError: '',
    );
    if (updated == null) {
      return;
    }
    await _sendNextTransferChunkSafely(updated, message,
        offset: control.resumeOffset);
  }

  Future<void> _handleRestart(TransferControl control) async {
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming ||
        isTerminalFileTransferState(transfer.state)) {
      return;
    }
    await _clearActiveIncomingTransfer(
      transfer.transferId,
      flush: false,
      releaseRuntime: false,
    );
    final tempFile = File(transfer.tempPath);
    if (tempFile.existsSync()) {
      await tempFile.writeAsBytes(const <int>[], flush: true);
    }
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.negotiating,
      committedBytes: 0,
      lastError: '',
    );
    await _sendReadyForIncomingTransfer(transfer.transferId);
  }

  Future<void> _handleTransferProgress(TransferControl control) async {
    final windowEnd = _outgoingWindowEndOffsets[control.transferId];
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing) {
      return;
    }
    final nextState = stateAfterTransferProgress(
      currentState: transfer.state,
      committedBytes: control.resumeOffset,
      size: control.size,
    );
    if (nextState == null) {
      _outgoingWindowSentAt.remove(control.transferId);
      _outgoingWindowEndOffsets.remove(control.transferId);
      return;
    }
    final updated = await _updateTransfer(
      control.transferId,
      state: nextState,
      committedBytes: control.resumeOffset,
      lastError: '',
    );
    if (updated == null ||
        updated.direction != FileTransferDirection.outgoing) {
      return;
    }
    if (_transferRuntime.activeOutgoingFor(updated.peerUid) !=
        updated.transferId) {
      final decision = _transferRuntime.enqueue(
        peerId: updated.peerUid,
        transferId: updated.transferId,
        direction: FileTransferDirection.outgoing,
      );
      if (decision == TransferRuntimeDecision.queued) {
        return;
      }
    }
    if (control.resumeOffset >= updated.size) {
      _outgoingWindowSentAt.remove(control.transferId);
      _outgoingWindowEndOffsets.remove(control.transferId);
      return;
    }
    if (windowEnd != null && control.resumeOffset < windowEnd) {
      return;
    }
    final sentAt = _outgoingWindowSentAt.remove(control.transferId);
    if (sentAt != null) {
      final rttMs =
          ((DateTime.now().microsecondsSinceEpoch - sentAt) / 1000).round();
      logger.i(
        'resumable ack window transfer=${control.transferId} '
        'committed=${control.resumeOffset}/${control.size} rttMs=$rttMs',
      );
    }
    _outgoingWindowEndOffsets.remove(control.transferId);
    final message =
        await LocalDatabase().fetchMessageByUuid(updated.messageUuid);
    if (message == null) {
      return;
    }
    await _sendNextTransferChunkSafely(updated, message,
        offset: control.resumeOffset);
  }

  Future<void> _handleTransferComplete(TransferControl control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.completed,
      committedBytes: control.size,
      lastError: '',
    );
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer != null &&
        _transferRuntime.activeOutgoingFor(transfer.peerUid) ==
            control.transferId) {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: control.transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingWindowSentAt.remove(control.transferId);
    _outgoingWindowEndOffsets.remove(control.transferId);
  }

  Future<void> _handlePeerPause(TransferControl control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.paused,
      lastError: control.errorMessage,
    );
  }

  Future<void> _handlePeerCancel(TransferControl control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.canceled,
      lastError: control.errorMessage,
    );
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer != null &&
        _transferRuntime.activeIncomingFor(transfer.peerUid) ==
            control.transferId) {
      await _clearActiveIncomingTransfer(control.transferId, flush: true);
      await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
    }
    if (transfer != null &&
        _transferRuntime.activeOutgoingFor(transfer.peerUid) ==
            control.transferId) {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: control.transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingWindowSentAt.remove(control.transferId);
    _outgoingWindowEndOffsets.remove(control.transferId);
  }

  Future<void> _handlePeerError(TransferControl control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.failed,
      lastError: control.errorMessage,
    );
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer != null &&
        _transferRuntime.activeIncomingFor(transfer.peerUid) ==
            control.transferId) {
      await _clearActiveIncomingTransfer(control.transferId, flush: true);
      await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
    }
    if (transfer != null &&
        _transferRuntime.activeOutgoingFor(transfer.peerUid) ==
            control.transferId) {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: control.transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingWindowSentAt.remove(control.transferId);
    _outgoingWindowEndOffsets.remove(control.transferId);
    if (control.errorMessage.isNotEmpty) {
      _dispatchToAll((event) => event.onNotice(control.errorMessage));
    }
  }

  Future<void> _recoverIncomingTransferChunk({
    required String transferId,
    required String reason,
  }) async {
    logger.i('resumable receive recovery transfer=$transferId reason=$reason');
    _clearIncomingTransferPerf(transferId);
    _clearPendingIncomingChunk(transferId);
    _incomingBytesSinceProgress[transferId] = 0;
    await _clearActiveIncomingTransfer(
      transferId,
      flush: true,
      releaseRuntime: false,
    );
    final transfer = await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null || isTerminalFileTransferState(transfer.state)) {
      return;
    }
    await _sendReadyForIncomingTransfer(transferId);
  }

  Future<void> _sendNextTransferChunkSafely(
    FileTransferData transfer,
    MessageData message, {
    required int offset,
  }) async {
    try {
      await _sendNextTransferChunk(transfer, message, offset: offset);
    } catch (error, stackTrace) {
      await _handleOutgoingTransferError(transfer, error, stackTrace);
    }
  }

  Future<void> _handleOutgoingTransferError(
    FileTransferData transfer,
    Object error,
    StackTrace stackTrace,
  ) async {
    final errorMessage = _outgoingTransferErrorMessage(error);
    logger.i(
      'outgoing transfer failed transfer=${transfer.transferId} '
      'peer=${transfer.peerUid} error=$error\n$stackTrace',
    );
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.failed,
      lastError: errorMessage,
    );
    if (_transferRuntime.activeOutgoingFor(transfer.peerUid) ==
        transfer.transferId) {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transfer.transferId,
        direction: FileTransferDirection.outgoing,
      );
    }
    _outgoingWindowSentAt.remove(transfer.transferId);
    _outgoingWindowEndOffsets.remove(transfer.transferId);
    if (isConnectedTo(transfer.peerUid) || transfer.peerUid == receiver) {
      _sendTransferControlTo(
        transfer.peerUid,
        TransferControl(
          action: TransferAction.error,
          transferId: transfer.transferId,
          name: '',
          size: transfer.size,
          fileTimestamp: 0,
          checksumAlgorithm: transfer.checksumAlgorithm,
          checksumValue: transfer.checksumValue,
          chunkSize: transfer.chunkSize,
          resumeOffset: transfer.committedBytes,
          resumeProofHash: '',
          errorCode: 'source',
          errorMessage: errorMessage,
        ),
      );
    }
    _dispatchToAll((event) => event.onNotice(errorMessage));
  }

  String _outgoingTransferErrorMessage(Object error) {
    if (error is FileSystemException) {
      final detail = error.message.isNotEmpty
          ? error.message
          : error.osError?.message ?? error.toString();
      return '发送文件失败：$detail';
    }
    return '发送文件失败：$error';
  }

  Future<void> _sendNextTransferChunk(
    FileTransferData transfer,
    MessageData message, {
    required int offset,
  }) async {
    if (!isConnectedTo(transfer.peerUid) && transfer.peerUid != receiver) {
      return;
    }
    if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
        transfer.transferId) {
      return;
    }
    final source = _transferSourceForMessage(message, transfer);
    final ranges = buildTransferWindowFrames(
      startOffset: offset,
      totalSize: transfer.size,
      windowSize: transfer.chunkSize,
      framePayloadSize: transferFramePayloadSize,
    );
    if (ranges.isEmpty) {
      return;
    }
    final windowLength = ranges.last.offset + ranges.last.length - offset;
    final stopwatch = Stopwatch()..start();
    _outgoingWindowSentAt[transfer.transferId] =
        DateTime.now().microsecondsSinceEpoch;
    _outgoingWindowEndOffsets[transfer.transferId] = offset + windowLength;
    var frameCount = 0;
    for (final range in ranges) {
      if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
          transfer.transferId) {
        return;
      }
      final buffer = await source.readRange(range.offset, range.length);
      if (buffer.length != range.length) {
        throw FileSystemException(
          'Unexpected EOF while reading transfer chunk',
          message.path,
        );
      }
      final rawRanges = buildTransferRawPayloadFrames(
        startOffset: 0,
        payloadLength: buffer.length,
        rawFramePayloadSize: transferRawFramePayloadSize,
      );
      for (final rawRange in rawRanges) {
        if (_transferRuntime.activeOutgoingFor(transfer.peerUid) !=
            transfer.transferId) {
          return;
        }
        if (!_sendBytesToPeer(
          transfer.peerUid,
          TransferChunkFrame(
            transferId: transfer.transferId,
            offset: range.offset + rawRange.offset,
            payload: Uint8List.sublistView(
              buffer,
              rawRange.offset,
              rawRange.offset + rawRange.length,
            ),
          ).encode(),
        )) {
          return;
        }
        frameCount++;
      }
    }
    stopwatch.stop();
    logger.i(
      'resumable send window transfer=${transfer.transferId} '
      'offset=$offset bytes=$windowLength frames=$frameCount '
      'frameBytes=$transferRawFramePayloadSize '
      'enqueueMs=${stopwatch.elapsedMilliseconds} '
      'enqueueRate=${_formatTransferRate(windowLength, stopwatch.elapsedMicroseconds)}',
    );
  }

  Future<void> _handleTransferChunk(TransferChunkFrame frame) async {
    var transfer = _receivingTransfers[frame.transferId];
    transfer ??= await LocalDatabase().fetchFileTransfer(frame.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming) {
      return;
    }
    if (transfer.state == FileTransferState.canceled ||
        transfer.state == FileTransferState.failed ||
        transfer.state == FileTransferState.completed) {
      return;
    }
    if (_transferRuntime.activeIncomingFor(transfer.peerUid) !=
        transfer.transferId) {
      return;
    }
    final currentSink = _receivingTransferSinks[transfer.transferId];
    final expectedOffset = currentSink == null
        ? transfer.committedBytes
        : _receivingTransferOffsets[transfer.transferId] ??
            transfer.committedBytes;
    if (frame.offset != expectedOffset) {
      await _recoverIncomingTransferChunk(
        transferId: transfer.transferId,
        reason:
            'unexpected offset expected=$expectedOffset actual=${frame.offset}',
      );
      return;
    }

    final tempFile = File(transfer.tempPath);
    if (!tempFile.existsSync()) {
      await tempFile.parent.create(recursive: true);
      await tempFile.create(recursive: true);
    }
    if (currentSink == null) {
      final currentLength = await tempFile.length();
      if (currentLength > frame.offset) {
        final writer = await tempFile.open(mode: FileMode.write);
        try {
          await writer.truncate(frame.offset);
        } finally {
          await writer.close();
        }
      } else if (currentLength < frame.offset) {
        await _recoverIncomingTransferChunk(
          transferId: transfer.transferId,
          reason:
              'temp file shorter than expected length=$currentLength offset=${frame.offset}',
        );
        return;
      }
      _receivingTransferSinks[transfer.transferId] =
          tempFile.openWrite(mode: FileMode.append);
      _receivingTransfers[transfer.transferId] = transfer;
      _receivingTransferOffsets[transfer.transferId] = frame.offset;
      if (_shouldStreamChecksum(
        transfer.checksumAlgorithm,
        transfer.checksumValue,
      )) {
        _receivingChecksums[transfer.transferId] =
            await streamingChecksumForFilePrefix(
          tempFile,
          algorithm: transfer.checksumAlgorithm,
          end: frame.offset,
        );
      } else {
        _receivingChecksums.remove(transfer.transferId);
      }
    }

    _receivingTransferSinks[transfer.transferId]?.add(frame.payload);
    _receivingChecksums[transfer.transferId]?.add(frame.payload);
    final committedBytes = frame.offset + frame.payload.length;
    _receivingTransferOffsets[transfer.transferId] = committedBytes;

    final bytesSinceProgress =
        (_incomingBytesSinceProgress[transfer.transferId] ?? 0) +
            frame.payload.length;
    final framesSinceProgress =
        (_incomingFramesSinceProgress[transfer.transferId] ?? 0) + 1;
    _incomingBytesSinceProgress[transfer.transferId] = bytesSinceProgress;
    _incomingFramesSinceProgress[transfer.transferId] = framesSinceProgress;
    _incomingWindowStartedAt.putIfAbsent(
      transfer.transferId,
      () => DateTime.now().microsecondsSinceEpoch,
    );
    final startedAt = _incomingWindowStartedAt[transfer.transferId] ??
        DateTime.now().microsecondsSinceEpoch;
    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final elapsedMicros = nowMicros - startedAt;
    final windowEnd = _incomingWindowEndOffsets[transfer.transferId];
    final reachedWindowEnd = windowEnd != null && committedBytes >= windowEnd;

    if (!shouldEmitTransferUiProgress(
      bytesSinceLastUiProgress: bytesSinceProgress,
      elapsedSinceLastUiProgress: Duration(microseconds: elapsedMicros),
      committedBytes: committedBytes,
      totalSize: transfer.size,
      force: reachedWindowEnd,
    )) {
      return;
    }

    final dbStopwatch = Stopwatch()..start();
    final currentTransfer =
        await LocalDatabase().fetchFileTransfer(transfer.transferId);
    final nextState = currentTransfer == null
        ? null
        : stateAfterTransferProgress(
            currentState: currentTransfer.state,
            committedBytes: committedBytes,
            size: currentTransfer.size,
          );
    if (currentTransfer == null || nextState == null) {
      await _clearActiveIncomingTransfer(transfer.transferId, flush: true);
      dbStopwatch.stop();
      return;
    }
    final updated = await _updateTransfer(
      transfer.transferId,
      state: nextState,
      committedBytes: committedBytes,
      lastError: '',
    );
    dbStopwatch.stop();
    if (updated == null) {
      return;
    }
    _receivingTransfers[updated.transferId] = updated;

    _sendTransferControlTo(
      updated.peerUid,
      TransferControl(
        action: TransferAction.progress,
        transferId: updated.transferId,
        name: '',
        size: updated.size,
        fileTimestamp: 0,
        checksumAlgorithm: updated.checksumAlgorithm,
        checksumValue: updated.checksumValue,
        chunkSize: updated.chunkSize,
        resumeOffset: committedBytes,
        resumeProofHash: '',
        errorCode: '',
        errorMessage: '',
      ),
    );

    if (reachedWindowEnd || committedBytes >= updated.size) {
      logger.i(
        'resumable recv window transfer=${updated.transferId} '
        'committed=$committedBytes/${updated.size} bytes=$bytesSinceProgress '
        'frames=$framesSinceProgress flush=false '
        'windowMs=${(elapsedMicros / 1000).round()} '
        'dbMs=${dbStopwatch.elapsedMilliseconds} '
        'rate=${_formatTransferRate(bytesSinceProgress, elapsedMicros)}',
      );
    }
    _incomingBytesSinceProgress[updated.transferId] = 0;
    _incomingFramesSinceProgress[updated.transferId] = 0;
    _incomingWindowStartedAt[updated.transferId] =
        DateTime.now().microsecondsSinceEpoch;
    if (reachedWindowEnd) {
      _incomingWindowEndOffsets.remove(updated.transferId);
    }

    if (committedBytes >= updated.size) {
      await _finalizeIncomingResumableTransfer(updated);
    }
  }

  Future<void> _finalizeIncomingResumableTransfer(
      FileTransferData transfer) async {
    await _closeReceivingTransferFile(transfer.transferId, flush: true);
    final tempFile = File(transfer.tempPath);
    if (_hasExpectedChecksum(
      transfer.checksumAlgorithm,
      transfer.checksumValue,
    )) {
      final actualChecksum =
          _receivingChecksums.remove(transfer.transferId)?.close() ??
              await fileChecksum(
                tempFile,
                algorithm: transfer.checksumAlgorithm,
              );
      if (actualChecksum != transfer.checksumValue) {
        await _updateTransfer(
          transfer.transferId,
          state: FileTransferState.failed,
          lastError: '文件校验失败，已暂停续传',
        );
        _sendTransferControlTo(
          transfer.peerUid,
          TransferControl(
            action: TransferAction.error,
            transferId: transfer.transferId,
            name: '',
            size: transfer.size,
            fileTimestamp: 0,
            checksumAlgorithm: transfer.checksumAlgorithm,
            checksumValue: transfer.checksumValue,
            chunkSize: transfer.chunkSize,
            resumeOffset: transfer.committedBytes,
            resumeProofHash: '',
            errorCode: 'checksum',
            errorMessage: '文件校验失败，已暂停续传',
          ),
        );
        await _clearActiveIncomingTransfer(
          transfer.transferId,
          flush: false,
        );
        await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
        return;
      }
    }
    final finalFile = File(transfer.finalPath);
    if (finalFile.existsSync()) {
      await finalFile.delete();
    }
    final message =
        await LocalDatabase().fetchMessageByUuid(transfer.messageUuid);
    if (message?.fileTimestamp != null && (message!.fileTimestamp ?? 0) > 0) {
      await tempFile.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(message.fileTimestamp!),
      );
    }
    await tempFile.rename(transfer.finalPath);
    await notifyFileVisibleToAndroidPickers(transfer.finalPath);
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.completed,
      committedBytes: transfer.size,
      lastError: '',
    );
    _sendTransferControlTo(
      transfer.peerUid,
      TransferControl(
        action: TransferAction.complete,
        transferId: transfer.transferId,
        name: '',
        size: transfer.size,
        fileTimestamp: 0,
        checksumAlgorithm: transfer.checksumAlgorithm,
        checksumValue: transfer.checksumValue,
        chunkSize: transfer.chunkSize,
        resumeOffset: transfer.size,
        resumeProofHash: '',
        errorCode: '',
        errorMessage: '',
      ),
    );
    await _clearActiveIncomingTransfer(
      transfer.transferId,
      flush: false,
    );
    await _startNextQueuedIncomingTransfer(peerId: transfer.peerUid);
  }

  Future<bool> _fileTransferUsesV3(FileTransferData transfer) async {
    final message = await LocalDatabase().fetchMessageByUuid(
      transfer.messageUuid,
    );
    final metadata = _FileTransferMetadata.fromContent(message?.content);
    return metadata?.protocolVersion == fileTransferV3ProtocolVersion;
  }

  Future<void> _startNextQueuedIncomingTransfer({String? peerId}) async {
    final peerIds = <String>{
      if (peerId?.isNotEmpty ?? false) peerId!,
      ...connectedPeerIds,
      if (receiver.isNotEmpty) receiver,
    };
    for (final candidatePeerId in peerIds) {
      if (_transferRuntime.activeIncomingFor(candidatePeerId) != null) {
        continue;
      }
      final items = await LocalDatabase().fetchRecoverableFileTransfersForPeer(
        candidatePeerId,
        direction: FileTransferDirection.incoming,
      );
      items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final item in items) {
        if (item.state == FileTransferState.queued ||
            item.state == FileTransferState.waitingReconnect) {
          if (await _fileTransferUsesV3(item)) {
            await _sendFileTransferV3Ready(item.transferId);
          } else {
            await _sendReadyForIncomingTransfer(item.transferId);
          }
          return;
        }
      }
    }
  }

  Future<void> _markRecoverableTransfersWaitingReconnect() async {
    final peerIds = <String>{
      ...connectedPeerIds,
      if (receiver.isNotEmpty) receiver,
    };
    for (final peerId in peerIds) {
      final items =
          await LocalDatabase().fetchRecoverableFileTransfersForPeer(peerId);
      for (final item in items) {
        if (item.state == FileTransferState.completed ||
            item.state == FileTransferState.failed ||
            item.state == FileTransferState.canceled) {
          continue;
        }
        await _updateTransfer(
          item.transferId,
          state: FileTransferState.waitingReconnect,
        );
      }
    }
  }

  Future<void> _closeReceivingTransferFile(
    String transferId, {
    bool flush = false,
  }) async {
    final writer = _receivingTransferWritersV3.remove(transferId);
    if (writer != null) {
      if (flush) {
        await writer.flush();
      }
      await writer.close();
    }
    final sink = _receivingTransferSinks.remove(transferId);
    if (sink != null) {
      if (flush) {
        await sink.flush();
      }
      await sink.close();
    }
  }

  Future<void> _closeAllReceivingTransferFiles({bool flush = false}) async {
    final writers = _receivingTransferWritersV3.values.toList(growable: false);
    _receivingTransferWritersV3.clear();
    for (final writer in writers) {
      if (flush) {
        await writer.flush();
      }
      await writer.close();
    }
    final sinks = _receivingTransferSinks.values.toList(growable: false);
    _receivingTransferSinks.clear();
    for (final sink in sinks) {
      if (flush) {
        await sink.flush();
      }
      await sink.close();
    }
  }

  Future<void> _clearActiveIncomingTransfer(
    String transferId, {
    bool flush = false,
    bool releaseRuntime = true,
  }) async {
    final transfer = _receivingTransfers[transferId] ??
        await LocalDatabase().fetchFileTransfer(transferId);
    await _closeReceivingTransferFile(transferId, flush: flush);
    _receivingTransfers.remove(transferId);
    _receivingChecksums.remove(transferId);
    _receivingTransferOffsets.remove(transferId);
    if (releaseRuntime && transfer != null) {
      _transferRuntime.complete(
        peerId: transfer.peerUid,
        transferId: transferId,
        direction: FileTransferDirection.incoming,
      );
    }
    _clearIncomingTransferPerf(transferId);
    _clearPendingIncomingChunk(transferId);
  }

  Future<void> _closeResumableHandles() async {
    await _closeAllReceivingTransferFiles(flush: true);
    _receivingTransfers.clear();
    _receivingChecksums.clear();
    _receivingTransferOffsets.clear();
    _receivingTransferWritersV3.clear();
    _transferRuntime.clearAll();
    _pendingIncomingChunkHeadersByPeer.clear();
    _pendingIncomingRawOffsetsByPeer.clear();
    _pendingIncomingRawRemainingByPeer.clear();
    _incomingBytesSinceProgress.clear();
    _incomingFramesSinceProgress.clear();
    _incomingWindowStartedAt.clear();
    _outgoingWindowSentAt.clear();
    _outgoingTransferSequences.clear();
    _incomingWindowEndOffsets.clear();
    _outgoingWindowEndOffsets.clear();
  }

  Future<void> _resumeRecoverableOutgoingTransfers() async {
    final peerIds = <String>{
      ...connectedPeerIds,
      if (receiver.isNotEmpty) receiver,
    };
    for (final peerId in peerIds) {
      if (!_supportsFileTransferV3For(peerId)) {
        continue;
      }
      final items = await LocalDatabase().fetchRecoverableFileTransfersForPeer(
        peerId,
        direction: FileTransferDirection.outgoing,
      );
      items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final item in items) {
        if (item.state == FileTransferState.completed ||
            item.state == FileTransferState.failed ||
            item.state == FileTransferState.canceled) {
          continue;
        }
        final message = await LocalDatabase().fetchMessageByUuid(
          item.messageUuid,
        );
        if (message != null) {
          _sendFileTransferV3OfferTo(item.peerUid, message);
        }
        await _updateTransfer(
          item.transferId,
          state: FileTransferState.negotiating,
        );
      }
    }
  }
}

class _FileTransferMetadata {
  const _FileTransferMetadata({
    required this.checksumAlgorithm,
    required this.checksumValue,
    required this.chunkSize,
    required this.protocolVersion,
  });

  final String checksumAlgorithm;
  final String checksumValue;
  final int chunkSize;
  final int protocolVersion;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'checksumAlgorithm': checksumAlgorithm,
      'checksumValue': checksumValue,
      'chunkSize': chunkSize,
      'protocolVersion': protocolVersion,
    };
  }

  static _FileTransferMetadata? fromContent(String? content) {
    if (content == null || content.isEmpty) {
      return null;
    }
    try {
      return _FileTransferMetadata.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  factory _FileTransferMetadata.fromJson(Map<String, dynamic> json) {
    return _FileTransferMetadata(
      checksumAlgorithm: json['checksumAlgorithm'] as String? ??
          WsSvrManager.defaultTransferChecksumAlgorithm,
      checksumValue: json['checksumValue'] as String? ?? '',
      chunkSize: json['chunkSize'] as int? ?? WsSvrManager._transferChunkSize,
      protocolVersion: json['protocolVersion'] as int? ?? 1,
    );
  }
}
