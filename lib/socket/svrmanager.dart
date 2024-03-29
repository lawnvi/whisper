import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:path/path.dart' as p;

import '../helper/file.dart';

abstract class ISocketEvent {
  void onError();

  void onMessage(MessageData messageData);

  void onProgress(int size, length);

  void onClose();

  void onConnect();

  void onAuth(DeviceData? deviceData, String msg, var callback);

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

  Uuid uuid = const Uuid();

  late HttpServer? _server = null;
  late WebSocketSink? _sink = null;
  late ISocketEvent? _event = null;
  late ISocketEvent? _eventBak = null;
  IOSink? _ioSink = null;
  int _currentSize = 0; // 大小
  int _currentLen = 0; // 已接收长度
  bool started = false;
  String receiver = "";
  String sender = "";

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
    close();
    var handler = webSocketHandler((webSocket) async {
      if (_sink != null) {
        var device = await LocalSetting().instance();
        var message = _buildMessage(MessageEnum.Auth, device.toJsonString(), "服务占线", "", 0, false);
        await webSocket.sink.add(utf8.encode(message.toJsonString()));
        return;
      }
      _sink = webSocket.sink;
      webSocket.stream.listen((message) {
        _listen(message);
      });
    });

    shelf_io.serve(handler, '0.0.0.0', port, shared: true).then((server) {
      _server = server;
      started = true;
      var host = "${server.address.host}:${server.port}";
      print('Serving at ws://$host');
      callback(true, "");
    }).onError((error, stackTrace) {
      print("服务启动失败: ${error}\n${stackTrace}");
      callback(false, error);
    });
  }

  Future<void> connectToServer(String host, var callback) async {
    try {
      close();
      final wsUrl = Uri.parse('ws://$host');
      WebSocketChannel channel = WebSocketChannel.connect(wsUrl);
      await channel.ready;
      _sink = channel.sink;
      _auth(true);
      channel.stream.listen((message) {
        _listen(message);
      });
      callback(true, "");
    } on Exception catch (e1) {
      callback(false, "连接失败：$e1");
    }
  }

  void close({bool closeServer=true}) {
    _sink?.close();
    _sink = null;
    if (closeServer) {
      started = false;
      _server?.close();
      _server = null;
    }
    receiver = "";
    print("服务已关闭");
  }

  void _send(String message) {
    _sink?.add(utf8.encode(message));
  }

  Future<void> _listen(Uint8List data) async {
    String str = "";
    MessageData message = MessageData(id: 0, sender: sender, receiver: receiver, name: "", clipboard: false, size: 0, type: MessageEnum.UNKONWN, timestamp: DateTime.now().second, uuid: '', acked: false, path: '', md5: '');
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

        if (_server != null) {
          var localTemp = await LocalDatabase().fetchDevice(device?.uid??"");
          var self = await LocalSetting().instance();
          if ((self.auth || localTemp != null && localTemp.auth)) {
            await _auth(true);
            receiver = device?.uid??"";
            _event?.afterAuth(true, device);
            return;
          }
        }

        print("AUTH message: ${message.message}");
        _event?.onAuth(device, message.message??"", (allow) async {
          print("AUTH message: ${message.message} ||| ${allow} ${_server == null}");
          if (_server != null) {
            await _auth(allow);
          }
          if (allow) {
            receiver = device?.uid??"";
          }else {
            close(closeServer: false);
          }
          _event?.afterAuth(allow, device);
        });
        break;
      }
      case MessageEnum.Ack: {
        print("收到ACK消息: ${message.uuid} ${message.type}\n${str}");
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
        print("收到消息：${message.content} sender: ${message.sender} receiver: ${message.receiver}");
        LocalDatabase().insertMessage(message);
        _ackMessage(message);
        if (message.clipboard) {
          if ((await LocalSetting().instance()).clipboard) {
            copyToClipboard(message.content??"");
          }
        }
        _event?.onMessage(message);
        print("文本消息：$str");
        break;
      }
      case MessageEnum.Heartbeat:
        // TODO: Handle this case.
        break;
      case MessageEnum.File: {
        print("收到文件：${message.name} size: ${message.size}");
        LocalDatabase().insertMessage(message);
        var path = await _prepareIOSink(message);
        print("保存文件: $path");
        _event?.onMessage(message);
        _ackMessage(message);
        break;
      }
      default: {
        if (_currentSize > 0 && _ioSink != null) {
          _ioSink?.add(data);
          _currentLen += data.length;
          print("recv ${data.length}, recved: $_currentLen all: $_currentSize");
          _event?.onProgress(_currentSize, _currentLen);
          if (_currentSize == _currentLen) {
            _ioSink?.close();
            _ioSink = null;
            _currentLen = 0;
            _currentSize = 0;
            print("recv over");
            // fileMD5
          }
        }else {
          print("未知消息：$str");
        }
      }
    }
  }

  MessageData _buildMessage(MessageEnum type, String content, msg, fileName, int size, bool clipboard, {String md5="", path=""}) {
    return MessageData(id: 0, sender: sender, receiver: receiver, name: fileName, clipboard: clipboard, size: size, type: type, content: content, message: msg, timestamp: DateTime.now().millisecondsSinceEpoch~/1000, acked: false, uuid: uuid.v4(), path: path, md5: md5);
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
    print("ack消息, uuid: ${data.uuid}");
    _send(MessageData.fromJson(json).toJsonString());
  }

  void sendMessage(String content, bool clipboard) {
    var message = _buildMessage(MessageEnum.Text, content, "", "", 0, clipboard);
    LocalDatabase().insertMessage(message);
    print("创建新消息, uuid: ${message.uuid}");
    _send(message.toJsonString());
  }

  void sendFile(String path) async {
    final file = File(path);
    final size = file.lengthSync();
    final fileName = p.basename(path);
    // final md5 = await fileMD5(file);
    var message = _buildMessage(MessageEnum.File, "", "", fileName, size, false, path: path, md5: "");
    LocalDatabase().insertMessage(message);
    _send(message.toJsonString());
  }

  void _sendFile(MessageData message) async {
    final file = File(message.path);
    final size = file.lengthSync();
    final fileName = p.basename(message.path);
    final fs = file.openRead();
    var start = DateTime.now().millisecondsSinceEpoch;
    print("start send $fileName, size: $size");
    var sendLen = 0;
    await for (var data in fs) {
      _sink?.add(data);
      sendLen += data.length;
      _event?.onProgress(size, sendLen);
    }
    print("send $fileName, size: $size use time: ${DateTime.now().millisecondsSinceEpoch - start}ms");
  }

  Future<String> _prepareIOSink(MessageData message) async {
    var appDir = await downloadDir();
    _currentSize = message.size;
    File file = File('${appDir.path}/${message.name}');
    var idx = 1;
    var arr = message.name.split(".");
    var before = message.name;
    var dot = "";
    if (arr.length > 1) {
      dot = arr[arr.length-1];
      before = message.name.substring(0, message.name.length - 1 - dot.length);
    }
    while (file.existsSync()) {
      file = File('${appDir.path}/$before-$idx.$dot');
      idx++;
    }
    _ioSink = file.openWrite();
    return file.path;
  }
}
