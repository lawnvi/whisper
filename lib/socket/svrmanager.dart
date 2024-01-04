import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:path/path.dart' as p;

abstract class ISocketEvent {
  void onError();

  void onMessage(MessageData messageData);

  void onProgress(int size, length);

  void onClose();

  void onConnect();

  void onAuth(DeviceData? deviceData, String msg, var callback);
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

  late HttpServer? _server = null;
  late WebSocketSink? _sink = null;
  late ISocketEvent? _event = null;
  IOSink? _ioSink = null;
  int _currentSize = 0;
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
    _event = event;
    if (uid.isNotEmpty) {
      sender = uid;
    }
  }

  void unregisterEvent() {
    _event = null;
  }

  void startServer(int port, var callback) {
    close();
    var handler = webSocketHandler((webSocket) async {
      if (_sink != null) {
        var device = await LocalSetting().instance();
        var message = _buildMessage(MessageEnum.Auth, device.toJsonString(), "服务占线", "", 0, false);
        await webSocket.sink.add(utf8.encode(message));
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

  void _listen(Uint8List data) {
    String str;
    MessageData message = MessageData(id: 0, sender: sender, receiver: receiver, name: "", clipboard: false, size: 0, type: MessageEnum.UNKONWN, timestamp: DateTime.now().second);
    try {
      str= utf8.decode(data);
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
        });
        break;
      }
      case MessageEnum.Text: {
        print("收到消息：${message.content} sender: ${message.sender} receiver: ${message.receiver}");
        _event?.onMessage(message);
        LocalDatabase().insertMessage(message);
        break;
      }
      case MessageEnum.Heartbeat:
        // TODO: Handle this case.
        break;
      case MessageEnum.File: {
        print("收到文件：${message.name} size: ${message.size}");
        LocalDatabase().insertMessage(message);
        _prepareIOSink(message);
        break;
      }
      default: {
        if (_currentSize > 0 && _ioSink != null) {
          _ioSink?.add(data);
          _currentSize -= data.length;
          print("recv ${data.length}, left: $_currentSize");
          if (_currentSize == 0) {
            _ioSink?.close();
            _ioSink = null;
            print("recv over");
          }
        }
      }
    }
  }

  String _buildMessage(MessageEnum type, String content, msg, fileName, int size, bool clipboard) {
    var message = MessageData(id: 0, sender: sender, receiver: receiver, name: fileName, clipboard: clipboard, size: size, type: type, content: content, message: msg, timestamp: DateTime.now().millisecondsSinceEpoch~/1000);
    return message.toJsonString();
  }

  Future<void> _auth(bool allow) async {
    var device = await LocalSetting().instance(online: true);
    var message = _buildMessage(MessageEnum.Auth, device.toJsonString(), allow?"":"拒绝连接", "", 0, false);
    _send(message);
  }

  void sendMessage(String content, bool clipboard) {
    var message = _buildMessage(MessageEnum.Text, content, "", "", 0, clipboard);
    _send(message);
  }

  void sendFile(String path) async {
    final file = File(path);
    final fs = file.openRead();
    final size = file.lengthSync();
    final fileName = p.basename(path);

    var message = _buildMessage(MessageEnum.File, "", "", fileName, size, false);
    _send(message);
    var start = DateTime.now().millisecond;
    print("start send $fileName, size: $size");
    await for (var data in fs) {
      _sink?.add(data);
    }
    print("send $fileName, size: $size use time: ${DateTime.now().millisecond - start}ms");
  }

  void _prepareIOSink(MessageData message) async {
    var appDir = await getApplicationDocumentsDirectory();
    _currentSize = message.size;
    File file = File('${appDir.path}/${message.name}');
    _ioSink = file.openWrite();
  }
}
