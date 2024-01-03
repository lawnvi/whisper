import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

abstract class ISocketEvent {
  void onError();

  void onMessage(String message);

  void onClose();

  void onConnect();
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
  bool started = false;
  bool isServer = false;

  void setEvent(ISocketEvent event) {
    _event = event;
  }

  void registerEvent(ISocketEvent event) {
    _event = event;
  }

  void unregisterEvent() {
    _event = null;
  }

  void startServer(int port, var callback) {
    close();
    var handler = webSocketHandler((webSocket) {
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
      channel.stream.listen((message) {
        _listen(message);
      });
      callback(true, "");
    } on Exception catch (e1) {
      callback(false, "连接失败：$e1");
    }
  }

  void close() {
    started = false;
    _sink?.close();
    _server?.close();
  }

  void sendMessage(String message) {
    _sink?.add(utf8.encode(message));
  }

  void _listen(Uint8List data) {
    _event?.onMessage(utf8.decode(data));
  }
}
