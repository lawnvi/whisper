import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:path/path.dart' as p;

import '../helper/file.dart';

abstract class ISocketEvent {
  void onError(String message);

  void onMessage(MessageData messageData);

  void onProgress(int size, length);

  void onClose();

  void onConnect();

  void onAuth(DeviceData? deviceData, bool asServer, String msg, var callback);

  void afterAuth(bool allow, DeviceData? device);
}

class WsSvrManager {

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
  ISocketEvent? _event;
  ISocketEvent? _eventBak;
  IOSink? _ioSink;
  File? _receivingFile;
  int _currentSize = 0; // 大小
  int _currentLen = 0; // 已接收长度
  bool started = false;
  bool asServer = true;
  String receiver = "";
  String sender = "";
  final List<MessageData> _sendingFiles = [];
  final _sendFileLock = Lock();
  Timer? _clientTimer;

  void setSender(String uid) {
    sender = uid;
  }

  void setEvent(ISocketEvent event) {
    _event = event;
  }

  void registerEvent(ISocketEvent event, {String uid = ""}) {
    if (_eventBak == null && _event != null) {
      _eventBak = _event;
    }
    _event = event;
    if (uid.isNotEmpty) {
      sender = uid;
    }
  }

  void unregisterEvent() {
    if (_eventBak != null) {
      _event = _eventBak;
      _eventBak = null;
    }else {
      _eventBak = _event;
    }
  }

  void startServer(int port, var callback) {
    close(closeServer: true);
    var handler = webSocketHandler((WebSocketChannel webSocket) async {
      if (_sink != null) {
        var device = await LocalSetting().instance();
        var message = _buildMessage(MessageEnum.Auth, device.toJsonString(), "服务占线", "", 0, false);
        webSocket.sink.add(utf8.encode(message.toJsonString()));
        return;
      }
      asServer = true;
      _sink = webSocket.sink;
      webSocket.stream.timeout(const Duration(minutes: 1)).listen(
        (message) {
          _listen(message);
        },
        onError: (Object error, StackTrace stackTrace) {
          logger.i("连接服务异常: $error\n$stackTrace");
          _event?.onError(error.toString());
        },
        onDone: () {
          logger.i("连接服务done");
          close();
        }
      );
    }, pingInterval: const Duration(seconds: 10));

    shelf_io.serve(handler, '0.0.0.0', port, shared: true).then((server) {
      _server = server;
      started = true;
      var host = "${server.address.host}:${server.port}";
      logger.i('Serving at ws://$host');
      callback(true, "");
    }).onError((error, stackTrace) {
      logger.i("服务启动失败: ${error}\n${stackTrace}");
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
      channel.stream.timeout(const Duration(minutes: 1)).listen((message) {
        _listen(message);
      }, onError: (error, stackTrace) {
        logger.i("客户端服务异常: $error\n$stackTrace");
        _event?.onError(error.toString());
      }, onDone: () {
        logger.i("客户端服务done");
        close();
      });
      // 开启一个定时器，每秒执行一次
      _clientTimer = Timer.periodic(const Duration(seconds: 20), (timer) {
        // 在这里执行你想要重复执行的代码
        _heartBeat();
      });
      callback(true, "");
    } on Exception catch (e1) {
      callback(false, "连接失败：$e1");
    }
  }

  void close({bool closeServer=false}) {
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
    _event?.onClose();
  }

  void _send(String message) {
    _sink?.add(utf8.encode(message));
  }

  Future<void> _listen(Uint8List data) async {
    String str = "";
    MessageData message = MessageData(id: 0, sender: sender, receiver: receiver, name: "", clipboard: false, size: 0, type: MessageEnum.UNKONWN, timestamp: DateTime.now().millisecondsSinceEpoch~/1000, uuid: '', acked: false, path: '', md5: '');
    try {
      str = utf8.decode(data);
      Map<String, dynamic> json = jsonDecode(str);
      message = MessageData.fromJson(json);
    }on Exception {
      // str = "";
    }

    switch(message.type) {
      case MessageEnum.Auth: {
        DeviceData? device;
        if (message.content != null) {
          device = DeviceData.fromJson(jsonDecode(message.content??""));
        }
        logger.i("AUTH message: ${message.sender} + $sender");
        if (asServer) {
          var localTemp = await LocalDatabase().fetchDevice(device?.uid??"");
          var self = await LocalSetting().instance();
          if ((self.auth || localTemp != null && localTemp.auth)) {
            await _auth(true);
            receiver = device?.uid??"";
            _event?.afterAuth(true, device);
            return;
          }
        }

        logger.i("AUTH message: ${message.sender} - $sender");
        _event?.onAuth(device, asServer, message.message??"", (allow) async {
          logger.i("AUTH message: ${message.message} ||| $allow");
          if (asServer) {
            await _auth(allow);
          }
          if (allow) {
            receiver = device?.uid??"";
          }else {
            close();
          }
          _event?.afterAuth(allow, device);
        });
        break;
      }
      case MessageEnum.Ack: {
        logger.i("收到ACK消息: ${message.uuid} ${message.type}\n$str");
        var msg = await LocalDatabase().ackMessage(message);
        if (msg != null) {
          _event?.onMessage(msg);
          if (msg.type == MessageEnum.File) {
            _sendFile(msg);
          }
        }
        break;
      }
      case MessageEnum.Text: {
        logger.i("收到消息：${message.content} sender: ${message.sender} receiver: ${message.receiver}");
        LocalDatabase().insertMessage(message);
        _ackMessage(message);
        if (message.clipboard) {
          if ((await LocalSetting().instance()).clipboard) {
            copyToClipboard(message.content??"");
          }
        }
        _event?.onMessage(message);
        logger.i("文本消息：$str");
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
      case MessageEnum.FileSignal: {
        final json = jsonDecode(message.content??"") as Map<String, dynamic>;
        var data = FileSignal.fromJson(json);
        logger.i('发送文件中 ${data.size}: ${(100*data.received/data.size).toStringAsFixed(2)}%'); // \r表示回车，将光标移到行首
        _event?.onProgress(data.size, data.received);
      }
      case MessageEnum.File: {
        await _sendFileLock.synchronized(() async {
          _sendingFiles.insert(0, message);
          if (_sendingFiles.length > 1) {
            return;
          }
          await _handleFileMsg(message);
        });
        break;
      }
      default: {
        if (_currentSize > 0 && _ioSink != null) {
          _ioSink?.add(data);
          _currentLen += data.length;
          // logger.i("recv ${data.length}, recved: $_currentLen all: $_currentSize");
          logger.i('接收文件中 $_currentSize: ${(100*_currentLen/_currentSize).toStringAsFixed(2)}%'); // \r表示回车，将光标移到行首
          _event?.onProgress(_currentSize, _currentLen);
          _sendFileSignal(_currentLen, _currentSize);
          if (_currentSize == _currentLen) {
            await _freeIoSink(sendFinish: true);
            logger.i("recv over file size: $_currentSize, check sending files size: ${_sendingFiles.length}");
            if (_sendingFiles.isNotEmpty) {
              await _handleFileMsg(_sendingFiles.last);
            }
            // fileMD5
          }
        }else {
          logger.i("未知消息：$str");
        }
      }
    }
  }

  Future<void> _freeIoSink({freeAll=false, sendFinish=false}) async {
    await _ioSink?.close();
    _ioSink = null;
    _currentLen = 0;
    _currentSize = 0;
    if (_receivingFile != null && sendFinish) {
      var path = _receivingFile!.path;
      await _receivingFile!.rename(path.substring(0, path.length - 11));
    }
    _receivingFile = null;
    if (freeAll) {
      _sendingFiles.clear();
    }else {
      _sendingFiles.removeLast();
    }
  }

  void _sendFileSignal(int received, int size, {String msgId=""}) {
    var data = FileSignal(size, received, msgId);
    var message = _buildMessage(MessageEnum.FileSignal, jsonEncode(data), "", "", 0, false);
    _send(message.toJsonString());
  }
  
  Future<void> _handleFileMsg(MessageData message) async {
    logger.i("收到文件：${message.name} size: ${message.size}");
    var path = await _prepareIOSink(message);
    var msgTemp = message.toJson();
    msgTemp["path"] = path;
    LocalDatabase().insertMessage(MessageData.fromJson(msgTemp));
    logger.i("保存文件: $path");
    _event?.onMessage(message);
    _ackMessage(message);
  }

  MessageData _buildMessage(MessageEnum type, String content, msg, fileName, int size, bool clipboard, {String md5="", path="", uid}) {
    return MessageData(id: 0, sender: sender, receiver: receiver, name: fileName, clipboard: clipboard, size: size, type: type, content: content, message: msg, timestamp: DateTime.now().millisecondsSinceEpoch~/1000, acked: false, uuid: uid??uuid.v4(), path: path, md5: md5);
  }

  Future<void> _auth(bool allow) async {
    var device = await LocalSetting().instance(online: true);
    var message = _buildMessage(MessageEnum.Auth, device.toJsonString(), allow?"":"拒绝连接", "", 0, false);
    _send(message.toJsonString());
  }

  void _ackMessage(MessageData data) {
    var json = data.toJson();
    json["type"] = MessageEnum.Ack.index;
    json["acked"] = true;
    logger.i("ack消息, ${data.type.name} uuid: ${data.uuid}");
    _send(MessageData.fromJson(json).toJsonString());
  }

  Future<void> _heartBeat() async {
    if (_sink == null) {
      return;
    }
    var message = _buildMessage(MessageEnum.Heartbeat, "", "", "", 0, false, uid: "");
    _send(message.toJsonString());
  }

  Future<void> sendMessage(String content, {clipboard=false}) async {
    if (_sink == null) {
      return;
    }
    if (clipboard && content.isEmpty) {
      var str = await getClipboardData()??"";
      content = str.trimRight();
    }
    if (content.trim().isEmpty) {
      return;
    }
    var message = _buildMessage(MessageEnum.Text, content, "", "", 0, clipboard);
    LocalDatabase().insertMessage(message);
    logger.i("创建新消息, uuid: ${message.uuid}");
    _send(message.toJsonString());
  }

  Future<void> sendFile(String path) async {
    await _sendFileLock.synchronized(() async {
      if (_sink == null) {
        return;
      }
      final file = File(path);
      final size = file.lengthSync();
      final fileName = p.basename(path);
      // final md5 = await fileMD5(file);
      var message = _buildMessage(MessageEnum.File, "", "", fileName, size, false, path: path, md5: "");
      await LocalDatabase().insertMessage(message);
      _send(message.toJsonString());
    });
  }

  void _sendFile(MessageData message) async {
    final file = File(message.path);
    final size = file.lengthSync();
    final fileName = p.basename(message.path);
    final fs = file.openRead();
    var start = DateTime.now().millisecondsSinceEpoch;
    logger.i("start send $fileName, size: $size");
    // var sendLen = 0;
    await for (var data in fs) {
      _sink?.add(data);
      // sendLen += data.length;
      // _event?.onProgress(size, sendLen);
    }
    logger.i("send $fileName, size: $size use time: ${DateTime.now().millisecondsSinceEpoch - start}ms");
  }

  Future<String> _prepareIOSink(MessageData message) async {
    var appDir = await downloadDir();
    _currentSize = message.size;
    _receivingFile = File('${appDir.path}/${message.name}');
    var idx = 1;
    var arr = message.name.split(".");
    var before = message.name;
    var dot = "";
    if (arr.length > 1) {
      dot = arr[arr.length-1];
      before = message.name.substring(0, message.name.length - 1 - dot.length);
    }
    while (_receivingFile!.existsSync()) {
      _receivingFile = File('${appDir.path}/$before-$idx.$dot');
      idx++;
    }
    _receivingFile = File('${appDir.path}/$before-$idx.$dot.crdownload');
    if (await _receivingFile!.exists()) {
      await _receivingFile!.delete();
    }
    _ioSink = _receivingFile!.openWrite();
    return _receivingFile!.path;
  }
}
