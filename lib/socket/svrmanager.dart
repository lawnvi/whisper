import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
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

  void onClose();

  void onConnect();

  void onAuth(DeviceData? deviceData, bool asServer, String msg, var callback);

  void afterAuth(bool allow, DeviceData? device);
}

class WsSvrManager {
  static const Duration _serverPingInterval = Duration(seconds: 45);
  static const Duration _clientHeartbeatInterval = Duration(seconds: 15);
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

  bool get isConnected => _sink != null;

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
    _clientTimer?.cancel();
    _clientTimer = null;
    _freeIoSink(freeAll: true);
    _sink?.close();
    _sink = null;
    if (closeServer) {
      started = false;
      _server?.close();
      _server = null;
    }
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
            if (msg.type == MessageEnum.File) {
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
          await _sendFileLock.synchronized(() async {
            _sendingFiles.insert(0, message);
            if (_sendingFiles.length > 1) {
              return;
            }
            await _handleFileMsg(message);
          });
          break;
        }
      default:
        {
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
      final md5 = await fileMD5(file);
      var message = _buildMessage(
          MessageEnum.File, "", "", fileName, size, false,
          path: path, md5: md5, fileTimestamp: timestamp);
      await LocalDatabase().insertMessage(message);
      _send(message.toJsonString());
    });
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
