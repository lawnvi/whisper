import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/drift.dart' show Value;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/state/peer_profile.dart';
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
  static const int _transferChunkSize = 1024 * 1024;
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
  final Set<ISocketEvent> _listeners = <ISocketEvent>{};
  ISocketEvent? _primaryEvent;
  IOSink? _ioSink;
  File? _receivingFile;
  RandomAccessFile? _sendingFile;
  // RandomAccessFile? _savingFile;
  final int _bufferSize = 16 * 1024 * 1024;
  final int oneMb = 1024 * 1024;
  int _currentSize = 0; // 大小
  int _currentFileTimestamp = 0; // 修改时间
  int _currentLen = 0; // 已接收长度
  bool started = false;
  bool asServer = true;
  String receiver = "";
  String sender = "";
  final List<MessageData> _sendingFiles = [];
  final _sendFileLock = Lock();
  Timer? _clientTimer;
  PeerProfile? _remoteProfile;
  RandomAccessFile? _receivingTransferFile;
  String? _receivingTransferId;
  String? _activeOutgoingTransferId;

  bool get isConnected => _sink != null;
  bool get supportsResumableTransfer => _supportsResumableTransfer;
  bool get _supportsResumableTransfer =>
      _remoteProfile?.capabilities.fileResumeV1 == true;

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
      callback(listener);
    }
  }

  void _dispatchToPrimary(void Function(ISocketEvent event) callback) {
    final primaryEvent = _primaryEvent;
    if (primaryEvent != null) {
      callback(primaryEvent);
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

  Future<FileTransferData?> _updateTransfer(
    String transferId, {
    FileTransferState? state,
    int? committedBytes,
    String? lastError,
    String? finalPath,
    String? tempPath,
  }) async {
    await LocalDatabase().updateFileTransfer(
      transferId,
      state: state == null ? const Value.absent() : Value(state),
      committedBytes:
          committedBytes == null ? const Value.absent() : Value(committedBytes),
      lastError: lastError == null ? const Value.absent() : Value(lastError),
      finalPath: finalPath == null ? const Value.absent() : Value(finalPath),
      tempPath: tempPath == null ? const Value.absent() : Value(tempPath),
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
    );
    return _emitTransferById(transferId);
  }

  void startServer(int port, var callback) {
    close(closeServer: true);
    var handler = webSocketHandler((WebSocketChannel webSocket) async {
      if (_sink != null) {
        var device = await LocalSetting().instance();
        var message = _buildMessage(
            MessageEnum.Auth, device.toJsonString(), "服务占线/busy", "", 0, false);
        webSocket.sink.add(utf8.encode(message.toJsonString()));
        return;
      }
      asServer = true;
      _sink = webSocket.sink;
      webSocket.stream.listen((message) async {
        await _listen(message);
      }, onError: (Object error, StackTrace stackTrace) {
        logger.i("连接服务异常: $error\n$stackTrace");
        _dispatchToPrimary((event) => event.onError(error.toString()));
      }, onDone: () {
        logger.i("连接服务done");
        close();
      });
    }, pingInterval: _serverPingInterval);

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

  Future<void> connectToServer(String host, int port, var callback) async {
    try {
      close();
      final wsUrl = Uri.parse('ws://$host:$port');
      WebSocketChannel channel = WebSocketChannel.connect(wsUrl);
      await channel.ready;
      asServer = false;
      _sink = channel.sink;
      _auth(true);
      channel.stream.listen((message) async {
        await _listen(message);
      }, onError: (error, stackTrace) {
        logger.i("客户端服务异常: $error\n$stackTrace");
        _dispatchToPrimary((event) => event.onError(error.toString()));
      }, onDone: () {
        logger.i("客户端服务done");
        close();
      });
      // 开启一个定时器，每秒执行一次
      _clientTimer = Timer.periodic(_clientHeartbeatInterval, (timer) {
        // 在这里执行你想要重复执行的代码
        _heartBeat();
      });
      callback(true, "");
    } on Exception catch (e1) {
      callback(false, "连接失败：$e1");
    }
  }

  void close({bool closeServer = false}) {
    final hadActiveConnection = _sink != null ||
        _ioSink != null ||
        _clientTimer != null ||
        _receivingTransferFile != null ||
        receiver.isNotEmpty;
    if (!hadActiveConnection && !closeServer) {
      return;
    }

    _clientTimer?.cancel();
    _clientTimer = null;
    unawaited(_markRecoverableTransfersWaitingReconnect());
    unawaited(_closeResumableHandles());
    _freeIoSink(freeAll: true);
    final currentSink = _sink;
    _sink = null;
    currentSink?.close();
    if (closeServer) {
      started = false;
      _server?.close();
      _server = null;
    }
    _remoteProfile = null;
    receiver = "";
    logger.i("服务已关闭");
    _dispatchToAll((event) => event.onClose());
  }

  void _send(String message) {
    _sink?.add(utf8.encode(message));
  }

  Future<void> _listen(Uint8List data) async {
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
      message = MessageData.fromJson(json);
    } on Exception {
      // str = "";
    }

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
          logger.i("AUTH message: ${message.sender} + $sender");
          if (asServer) {
            var localTemp =
                await LocalDatabase().fetchDevice(device?.uid ?? "");
            var self = await LocalSetting().instance();
            if ((self.auth || localTemp != null && localTemp.auth)) {
              await _auth(true);
              receiver = device?.uid ?? "";
              _remoteProfile = profile;
              _dispatchToAll((event) => event.onConnect());
              unawaited(_resumeRecoverableOutgoingTransfers());
              _dispatchToAll((event) => event.afterAuth(true, device));
              return;
            }
          }

          logger.i("AUTH message: ${message.sender} - $sender");
          _dispatchToPrimary((event) {
            event.onAuth(device, asServer, message.message ?? "",
                (allow) async {
              logger.i("AUTH message: ${message.message} ||| $allow");
              if (asServer) {
                await _auth(allow);
              }
              if (allow) {
                receiver = device?.uid ?? "";
                _remoteProfile = profile;
                _dispatchToAll((event) => event.onConnect());
                unawaited(_resumeRecoverableOutgoingTransfers());
              } else {
                close();
              }
              _dispatchToAll((listener) => listener.afterAuth(allow, device));
            });
          });
          break;
        }
      case MessageEnum.Ack:
        {
          if (message.uuid.isEmpty) {
            return;
          }
          logger.i("收到ACK消息: ${message.uuid} ${message.type}\n$str");
          var msg = await LocalDatabase().ackMessage(message);
          if (msg != null) {
            _dispatchToAll((event) => event.onMessage(msg));
            if (msg.type == MessageEnum.File && !_supportsResumableTransfer) {
              _sendFile(msg);
            }
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
              if (data['package'] == "com.android.mms") {
                var code = verifyCode(data["text"]);
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
          _ackMessage(message);
          break;
        }
      case MessageEnum.FileSignal:
        {
          final json =
              jsonDecode(message.content ?? "") as Map<String, dynamic>;
          var data = FileSignal.fromJson(json);
          // logger.i('发送文件中 ${data.size}: ${(100*data.received/data.size).toStringAsFixed(2)}% ${data.received}'); // \r表示回车，将光标移到行首
          if (data.size == data.received || data.received % _bufferSize == 0) {
            logger.i('send next chunk ${data.received}'); // \r表示回车，将光标移到行首
            await _sendFileChunk(sendOver: data.size == data.received);
          }
          if (data.size == data.received || data.received % oneMb == 0) {
            _dispatchToAll(
                (event) => event.onProgress(data.size, data.received));
          }
        }
      case MessageEnum.File:
        {
          if (_supportsResumableTransfer) {
            await _handleResumableFileMsg(message);
            break;
          }
          await _sendFileLock.synchronized(() async {
            _sendingFiles.insert(0, message);
            if (_sendingFiles.length > 1) {
              return;
            }
            await _handleFileMsg(message);
          });
          break;
        }
      case MessageEnum.TransferControl:
        {
          await _handleTransferControl(message);
          break;
        }
      default:
        {
          if (TransferChunkFrame.looksLikeFrame(data)) {
            await _handleTransferChunk(TransferChunkFrame.decode(data));
            return;
          }
          if (_currentSize > 0 && _ioSink != null) {
            _ioSink?.add(data);
            _currentLen += data.length;
            // logger.i('接收文件中 $_currentSize: ${(100*_currentLen/_currentSize).toStringAsFixed(2)}% size: $_currentLen'); // \r表示回车，将光标移到行首
            // await _savingFile?.writeFrom(data);
            // logger.i("recv ${data.length}, recved: $_currentLen all: $_currentSize");
            if (_currentLen == _currentSize || _currentLen % _bufferSize == 0) {
              // logger.i("recv a chunk: $_currentLen flush");
              await _ioSink?.flush();
              // logger.i("recv a chunk: $_currentLen flush over");
            }
            if (_currentSize == _currentLen || _currentLen % oneMb == 0) {
              _dispatchToAll(
                (event) => event.onProgress(_currentSize, _currentLen),
              );
              _sendFileSignal(_currentLen, _currentSize);
            }
            if (_currentSize == _currentLen) {
              final finishedSize = _currentSize;
              final completedMessage =
                  _sendingFiles.isNotEmpty ? _sendingFiles.last : null;
              final receiveCompleted =
                  await _finalizeReceivedFile(completedMessage);
              await _freeIoSink();
              if (receiveCompleted && finishedSize > 0) {
                _dispatchToAll(
                    (event) => event.onProgress(finishedSize, finishedSize));
              }
              logger.i(
                  "recv over file size: $_currentSize, check sending files size: ${_sendingFiles.length}");
              if (!receiveCompleted && completedMessage != null) {
                logger.i(
                  "recv file verification failed: ${completedMessage.name}",
                );
              }
              if (_sendingFiles.isNotEmpty) {
                await _handleFileMsg(_sendingFiles.last);
              }
            }
          } else {
            logger.i("未知消息：$str");
          }
        }
    }
  }

  Future<void> _freeIoSink({freeAll = false}) async {
    logger.i("close file");
    // await _ioSink?.flush();
    // await _savingFile?.close();
    await _ioSink?.close();
    _ioSink = null;
    _currentLen = 0;
    _currentSize = 0;
    _currentFileTimestamp = 0;
    _receivingFile = null;
    if (freeAll) {
      _sendingFiles.clear();
    } else {
      _sendingFiles.removeLast();
    }
    WakelockPlus.disable();
  }

  Future<void> _rejectIncomingFile(MessageData message, String notice) async {
    logger.i(notice);
    _dispatchToAll((event) => event.onNotice(notice));
    if (_sendingFiles.isNotEmpty) {
      _sendingFiles.removeLast();
    }
    if (_sendingFiles.isNotEmpty) {
      await _handleFileMsg(_sendingFiles.last);
    }
  }

  Future<bool> _finalizeReceivedFile(MessageData? message) async {
    final tempFile = _receivingFile;
    if (tempFile == null) {
      return false;
    }

    final expectedMd5 = message?.md5 ?? "";
    final finalPath = tempFile.path.substring(0, tempFile.path.length - 11);

    if (expectedMd5.isNotEmpty) {
      final actualMd5 = await fileMD5(tempFile);
      if (!isFileIntegrityValid(
        expectedMd5: expectedMd5,
        actualMd5: actualMd5,
      )) {
        try {
          await tempFile.delete();
        } catch (_) {}
        _dispatchToAll(
          (event) => event.onNotice(
            '文件校验失败，已丢弃损坏文件：${message?.name ?? ''}',
          ),
        );
        return false;
      }
    }

    if (_currentFileTimestamp > 0) {
      await tempFile.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(_currentFileTimestamp),
      );
    }
    await tempFile.rename(finalPath);
    return true;
  }

  void _sendFileSignal(int received, int size, {String msgId = ""}) {
    var data = FileSignal(size, received, msgId);
    var message = _buildMessage(
        MessageEnum.FileSignal, jsonEncode(data), "", "", 0, false);
    _send(message.toJsonString());
  }

  Future<void> _handleFileMsg(MessageData message) async {
    logger.i(
        "收到文件：${message.name} size: ${message.size} timestamp: ${message.fileTimestamp}");
    String path;
    try {
      path = await _prepareIOSink(message);
    } on FileSystemException catch (error) {
      await _rejectIncomingFile(message, error.message);
      return;
    } catch (error) {
      await _rejectIncomingFile(message, '接收 ${message.name} 失败：$error');
      return;
    }
    var msgTemp = message.toJson();
    msgTemp["path"] = path;
    var newMessage = MessageData.fromJson(msgTemp);
    await LocalDatabase().insertMessage(newMessage);
    // logger.i("保存文件: $path");
    _dispatchToAll((event) => event.onMessage(newMessage));
    _ackMessage(message);
  }

  MessageData _buildMessage(
      MessageEnum type, String content, msg, fileName, int size, bool clipboard,
      {String md5 = "", path = "", uid, fileTimestamp = 0}) {
    return MessageData(
        id: 0,
        sender: sender,
        receiver: receiver,
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

  Future<void> _auth(bool allow) async {
    var device = await LocalSetting().instance(online: true);
    final trustedPeerIds = await LocalDatabase().fetchTrustedPeerIds();
    final profile = PeerProfile(
      device: device,
      trustedPeerIds: trustedPeerIds,
      autoApproveNewDevices: await LocalSetting().autoApproveNewDevices(),
      autoConnectEnabled: await LocalSetting().autoConnectEnabled(),
      protocolVersion: 2,
      capabilities: const PeerCapabilities(fileResumeV1: true),
    );
    var message = _buildMessage(MessageEnum.Auth, profile.toJsonString(),
        allow ? "" : "拒绝连接", "", 0, false);
    _send(message.toJsonString());
  }

  void _ackMessage(MessageData data) {
    var json = data.toJson();
    json["type"] = MessageEnum.Ack.index;
    json["acked"] = true;
    // logger.i("ack消息, ${data.type.name} uuid: ${data.uuid}");
    _send(MessageData.fromJson(json).toJsonString());
  }

  Future<void> _heartBeat() async {
    if (_sink == null) {
      return;
    }
    var message =
        _buildMessage(MessageEnum.Heartbeat, "", "", "", 0, false, uid: "");
    _send(message.toJsonString());
  }

  Future<void> refreshConnectionLiveness() async {
    await _heartBeat();
  }

  Future<void> retryTransfer(String transferId) async {
    final transfer = await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null) {
      return;
    }
    if (_sink == null ||
        !_supportsResumableTransfer ||
        transfer.peerUid != receiver) {
      await _updateTransfer(
        transferId,
        state: FileTransferState.waitingReconnect,
        lastError: '',
      );
      return;
    }
    if (transfer.direction == FileTransferDirection.outgoing) {
      await _updateTransfer(
        transferId,
        state: FileTransferState.negotiating,
        lastError: '',
      );
      _sendTransferControl(
        TransferControl(
          action: TransferAction.resumeProbe,
          transferId: transfer.transferId,
          name: '',
          size: transfer.size,
          fileTimestamp: 0,
          checksumAlgorithm: transfer.checksumAlgorithm,
          checksumValue: transfer.checksumValue,
          chunkSize: transfer.chunkSize,
          resumeOffset: transfer.committedBytes,
          resumeProofHash: '',
          errorCode: '',
          errorMessage: '',
        ),
      );
      return;
    }
    await _updateTransfer(
      transferId,
      state: FileTransferState.negotiating,
      lastError: '',
    );
    await _sendReadyForIncomingTransfer(transferId);
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
    if (_sink != null &&
        _supportsResumableTransfer &&
        transfer.peerUid == receiver) {
      _sendTransferControl(
        TransferControl(
          action: TransferAction.cancel,
          transferId: transfer.transferId,
          name: '',
          size: transfer.size,
          fileTimestamp: 0,
          checksumAlgorithm: transfer.checksumAlgorithm,
          checksumValue: transfer.checksumValue,
          chunkSize: transfer.chunkSize,
          resumeOffset: transfer.committedBytes,
          resumeProofHash: '',
          errorCode: '',
          errorMessage: '',
        ),
      );
    }
    if (_receivingTransferId == transferId) {
      _receivingTransferId = null;
      await _startNextQueuedIncomingTransfer();
    }
    if (_activeOutgoingTransferId == transferId) {
      _activeOutgoingTransferId = null;
    }
  }

  Future<void> sendMessage(String content, {clipboard = false}) async {
    if (_sink == null) {
      return;
    }
    if (clipboard && content.isEmpty) {
      var str = await getClipboardText() ?? "";
      content = str.trimRight();
    }
    if (content.trim().isEmpty) {
      return;
    }
    var message =
        _buildMessage(MessageEnum.Text, content, "", "", 0, clipboard);
    await LocalDatabase().insertMessage(message);
    logger.i("创建新消息, uuid: ${message.uuid}");
    _send(message.toJsonString());
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
    _send(message.toJsonString());
  }

  Future<void> sendFile(String path) async {
    await _sendFileLock.synchronized(() async {
      if (_sink == null) {
        return;
      }
      final file = File(path);
      if (!file.existsSync() ||
          FileSystemEntity.typeSync(path) == FileSystemEntityType.directory) {
        return;
      }
      final size = file.lengthSync();
      final timestamp = (await file.lastModified()).millisecondsSinceEpoch;
      final fileName = p.basename(path);
      final now = DateTime.now().millisecondsSinceEpoch;
      String md5 = '';
      String content = '';
      if (_supportsResumableTransfer) {
        final checksumValue = await fileChecksum(file, algorithm: 'sha256');
        content = jsonEncode(
          _FileTransferMetadata(
            checksumAlgorithm: 'sha256',
            checksumValue: checksumValue,
            chunkSize: _transferChunkSize,
            protocolVersion: 2,
          ).toJson(),
        );
      } else {
        md5 = await fileMD5(file);
      }
      var message = _buildMessage(
          MessageEnum.File, content, "", fileName, size, false,
          path: path, md5: md5, fileTimestamp: timestamp);
      await LocalDatabase().insertMessage(message);
      if (_supportsResumableTransfer) {
        final metadata = _FileTransferMetadata.fromJson(
          jsonDecode(content) as Map<String, dynamic>,
        );
        await _persistTransfer(
          FileTransferData(
            transferId: message.uuid,
            messageUuid: message.uuid,
            peerUid: receiver,
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
      }
      _send(message.toJsonString());
    });
  }

  void _sendTransferControl(TransferControl control) {
    final message = _buildMessage(
      MessageEnum.TransferControl,
      jsonEncode(control.toJson()),
      '',
      '',
      0,
      false,
    );
    _send(message.toJsonString());
  }

  Future<void> _handleResumableFileMsg(MessageData message) async {
    final metadata = _FileTransferMetadata.fromContent(message.content);
    if (metadata == null) {
      await _handleFileMsg(message);
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
        _sendTransferControl(
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
      transfer = FileTransferData(
        transferId: message.uuid,
        messageUuid: message.uuid,
        peerUid: message.sender,
        direction: FileTransferDirection.incoming,
        state: _receivingTransferId == null
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
    }

    final existingMessage = await db.fetchMessageByUuid(message.uuid);
    if (existingMessage == null) {
      final json = message.toJson();
      json['path'] = transfer.finalPath;
      final newMessage = MessageData.fromJson(json);
      await db.insertMessage(newMessage);
      _dispatchToAll((event) => event.onMessage(newMessage));
    }
    _ackMessage(message);

    if (_receivingTransferId == null ||
        _receivingTransferId == transfer.transferId) {
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
        transfer.state == FileTransferState.canceled ||
        transfer.state == FileTransferState.failed) {
      return;
    }
    if (_receivingTransferId != null &&
        _receivingTransferId != transfer.transferId) {
      return;
    }
    await _sendReadyForIncomingTransfer(transfer.transferId);
  }

  Future<void> _sendReadyForIncomingTransfer(String transferId) async {
    final transfer = await LocalDatabase().fetchFileTransfer(transferId);
    if (transfer == null) {
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
    _receivingTransferId = transfer.transferId;
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
    _sendTransferControl(
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

  Future<void> _handleReady(TransferControl control) async {
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.outgoing) {
      return;
    }
    final message =
        await LocalDatabase().fetchMessageByUuid(transfer.messageUuid);
    if (message == null) {
      return;
    }
    final file = File(message.path);
    if (!file.existsSync()) {
      await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.failed,
        lastError: '源文件不存在，无法继续传输',
      );
      return;
    }
    if (file.lengthSync() != transfer.size) {
      await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.failed,
        lastError: '源文件已变化，无法继续传输',
      );
      return;
    }
    final currentChecksum = await fileChecksum(
      file,
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
    if (control.resumeOffset > 0) {
      final proof = await resumeProofHash(
        file,
        resumeOffset: control.resumeOffset,
        chunkSize: transfer.chunkSize,
      );
      if (proof != control.resumeProofHash) {
        _sendTransferControl(
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
    _activeOutgoingTransferId = transfer.transferId;
    final updated = await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.transferring,
      committedBytes: control.resumeOffset,
      lastError: '',
    );
    if (updated == null) {
      return;
    }
    await _sendNextTransferChunk(updated, message,
        offset: control.resumeOffset);
  }

  Future<void> _handleRestart(TransferControl control) async {
    final transfer =
        await LocalDatabase().fetchFileTransfer(control.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming) {
      return;
    }
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
    final updated = await _updateTransfer(
      control.transferId,
      state: control.resumeOffset >= control.size
          ? FileTransferState.verifying
          : FileTransferState.transferring,
      committedBytes: control.resumeOffset,
      lastError: '',
    );
    if (updated == null ||
        updated.direction != FileTransferDirection.outgoing) {
      return;
    }
    if (control.resumeOffset >= updated.size) {
      return;
    }
    final message =
        await LocalDatabase().fetchMessageByUuid(updated.messageUuid);
    if (message == null) {
      return;
    }
    await _sendNextTransferChunk(updated, message,
        offset: control.resumeOffset);
  }

  Future<void> _handleTransferComplete(TransferControl control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.completed,
      committedBytes: control.size,
      lastError: '',
    );
    if (_activeOutgoingTransferId == control.transferId) {
      _activeOutgoingTransferId = null;
    }
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
    if (_receivingTransferId == control.transferId) {
      _receivingTransferId = null;
      await _startNextQueuedIncomingTransfer();
    }
    if (_activeOutgoingTransferId == control.transferId) {
      _activeOutgoingTransferId = null;
    }
  }

  Future<void> _handlePeerError(TransferControl control) async {
    await _updateTransfer(
      control.transferId,
      state: FileTransferState.failed,
      lastError: control.errorMessage,
    );
    if (_receivingTransferId == control.transferId) {
      _receivingTransferId = null;
      await _startNextQueuedIncomingTransfer();
    }
    if (_activeOutgoingTransferId == control.transferId) {
      _activeOutgoingTransferId = null;
    }
    if (control.errorMessage.isNotEmpty) {
      _dispatchToAll((event) => event.onNotice(control.errorMessage));
    }
  }

  Future<void> _sendNextTransferChunk(
    FileTransferData transfer,
    MessageData message, {
    required int offset,
  }) async {
    if (_sink == null) {
      return;
    }
    final file = File(message.path);
    final reader = await file.open();
    try {
      await reader.setPosition(offset);
      final buffer = await reader.read(transfer.chunkSize);
      if (buffer.isEmpty) {
        return;
      }
      _sink?.add(
        TransferChunkFrame(
          transferId: transfer.transferId,
          offset: offset,
          payload: Uint8List.fromList(buffer),
        ).encode(),
      );
    } finally {
      await reader.close();
    }
  }

  Future<void> _handleTransferChunk(TransferChunkFrame frame) async {
    final transfer = await LocalDatabase().fetchFileTransfer(frame.transferId);
    if (transfer == null ||
        transfer.direction != FileTransferDirection.incoming) {
      return;
    }
    if (transfer.state == FileTransferState.canceled ||
        transfer.state == FileTransferState.failed ||
        transfer.state == FileTransferState.completed) {
      return;
    }
    if (_receivingTransferId != null &&
        _receivingTransferId != transfer.transferId) {
      return;
    }
    if (frame.offset != transfer.committedBytes) {
      await _sendReadyForIncomingTransfer(transfer.transferId);
      return;
    }

    final tempFile = File(transfer.tempPath);
    if (!tempFile.existsSync()) {
      await tempFile.parent.create(recursive: true);
      await tempFile.create(recursive: true);
    }
    final writer = await tempFile.open(mode: FileMode.write);
    try {
      await writer.setPosition(frame.offset);
      await writer.writeFrom(frame.payload);
      await writer.flush();
    } finally {
      await writer.close();
    }

    final committedBytes = frame.offset + frame.payload.length;
    final updated = await _updateTransfer(
      transfer.transferId,
      state: committedBytes >= transfer.size
          ? FileTransferState.verifying
          : FileTransferState.transferring,
      committedBytes: committedBytes,
      lastError: '',
    );
    if (updated == null) {
      return;
    }

    final proof = await resumeProofHash(
      tempFile,
      resumeOffset: committedBytes,
      chunkSize: updated.chunkSize,
    );
    _sendTransferControl(
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
        resumeProofHash: proof,
        errorCode: '',
        errorMessage: '',
      ),
    );

    if (committedBytes >= updated.size) {
      await _finalizeIncomingResumableTransfer(updated);
    }
  }

  Future<void> _finalizeIncomingResumableTransfer(
      FileTransferData transfer) async {
    final tempFile = File(transfer.tempPath);
    final actualChecksum = await fileChecksum(
      tempFile,
      algorithm: transfer.checksumAlgorithm,
    );
    if (actualChecksum != transfer.checksumValue) {
      await _updateTransfer(
        transfer.transferId,
        state: FileTransferState.failed,
        lastError: '文件校验失败，已暂停续传',
      );
      _sendTransferControl(
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
      _receivingTransferId = null;
      await _startNextQueuedIncomingTransfer();
      return;
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
    await _updateTransfer(
      transfer.transferId,
      state: FileTransferState.completed,
      committedBytes: transfer.size,
      lastError: '',
    );
    _sendTransferControl(
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
    _receivingTransferId = null;
    await _startNextQueuedIncomingTransfer();
  }

  Future<void> _startNextQueuedIncomingTransfer() async {
    if (receiver.isEmpty) {
      return;
    }
    final items = await LocalDatabase().fetchRecoverableFileTransfersForPeer(
      receiver,
      direction: FileTransferDirection.incoming,
    );
    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final item in items) {
      if (item.state == FileTransferState.queued ||
          item.state == FileTransferState.waitingReconnect) {
        await _sendReadyForIncomingTransfer(item.transferId);
        return;
      }
    }
  }

  Future<void> _markRecoverableTransfersWaitingReconnect() async {
    if (receiver.isEmpty) {
      return;
    }
    final items =
        await LocalDatabase().fetchRecoverableFileTransfersForPeer(receiver);
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

  Future<void> _closeResumableHandles() async {
    await _receivingTransferFile?.close();
    _receivingTransferFile = null;
    _receivingTransferId = null;
    _activeOutgoingTransferId = null;
  }

  Future<void> _resumeRecoverableOutgoingTransfers() async {
    if (!_supportsResumableTransfer || receiver.isEmpty) {
      return;
    }
    final items = await LocalDatabase().fetchRecoverableFileTransfersForPeer(
      receiver,
      direction: FileTransferDirection.outgoing,
    );
    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final item in items) {
      if (item.state == FileTransferState.completed ||
          item.state == FileTransferState.failed ||
          item.state == FileTransferState.canceled) {
        continue;
      }
      _sendTransferControl(
        TransferControl(
          action: TransferAction.resumeProbe,
          transferId: item.transferId,
          name: '',
          size: item.size,
          fileTimestamp: 0,
          checksumAlgorithm: item.checksumAlgorithm,
          checksumValue: item.checksumValue,
          chunkSize: item.chunkSize,
          resumeOffset: item.committedBytes,
          resumeProofHash: '',
          errorCode: '',
          errorMessage: '',
        ),
      );
      await _updateTransfer(
        item.transferId,
        state: FileTransferState.negotiating,
      );
    }
  }

  void _sendFile(MessageData message) async {
    WakelockPlus.enable();
    final file = File(message.path);
    final size = file.lengthSync();
    final fileName = p.basename(message.path);
    _sendingFile = await file.open();

    var start = DateTime.now().millisecondsSinceEpoch;
    logger.i("start send $fileName, size: $size");
    await _sendFileChunk();

    logger.i(
        "send $fileName, size: $size use time: ${DateTime.now().millisecondsSinceEpoch - start}ms");
  }

  Future<void> _sendFileChunk({sendOver = false}) async {
    if (_sendingFile == null) {
      logger.i("send file chunk _sending file is null");
      return;
    }

    if (sendOver) {
      logger.i("send file chunk over close");
      await _sendingFile?.close();
      _sendingFile = null;
      WakelockPlus.disable();
      return;
    }

    var buffer = await _sendingFile!.read(_bufferSize);

    int start;
    for (var i = 0; i < buffer.length;) {
      start = i;
      i = i + 64 * 1024;
      if (i > buffer.length) {
        i = buffer.length;
      }
      _sink?.add(buffer.sublist(start, i));
    }
    logger.i("send file chunk buffer ${buffer.length}");
  }

  Future<String> _prepareIOSink(MessageData message) async {
    var appDir = await downloadDir();
    final availableBytes = await availableBytesForPath(appDir.path);
    if (!hasEnoughStorageForFile(
      fileSize: message.size,
      availableBytes: availableBytes,
    )) {
      throw FileSystemException(
        '接收 ${message.name} 失败：存储空间不足',
        appDir.path,
      );
    }
    _currentSize = message.size;
    _currentFileTimestamp =
        message.fileTimestamp ?? DateTime.now().millisecondsSinceEpoch;
    _receivingFile = File('${appDir.path}/${message.name}');
    var idx = 1;
    var arr = message.name.split(".");
    var before = message.name;
    var dot = "";
    if (arr.length > 1) {
      dot = arr[arr.length - 1];
      before = message.name.substring(0, message.name.length - 1 - dot.length);
    }
    while (_receivingFile!.existsSync()) {
      _receivingFile = File('${appDir.path}/$before-$idx.$dot');
      idx++;
    }
    var path = _receivingFile!.path;
    _receivingFile = File('$path.crdownload');
    if (await _receivingFile!.exists()) {
      await _receivingFile!.delete();
    }
    // todo 无法访问时如何处理
    _ioSink = _receivingFile!.openWrite();
    // _savingFile = await _receivingFile!.open(mode: FileMode.write);
    WakelockPlus.enable();
    return path;
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
      checksumAlgorithm: json['checksumAlgorithm'] as String? ?? 'sha256',
      checksumValue: json['checksumValue'] as String? ?? '',
      chunkSize: json['chunkSize'] as int? ?? WsSvrManager._transferChunkSize,
      protocolVersion: json['protocolVersion'] as int? ?? 1,
    );
  }
}
