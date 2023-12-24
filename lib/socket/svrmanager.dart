import 'dart:async';
import 'dart:io';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';


abstract class ISocketEvent {
  void onError();

  void onMessage();

  void onClose();
}

abstract class IServerEvent {
  ISocketEvent onNewClient((bool ok, ISocketEvent event) callback);

  void onClose();

  void onError();

  void onListen(String host);
}

class WsSvrManager {
  final Map _clientMap = {};
  IServerEvent? serverEvent;


  Future<void> startServer(IServerEvent event) async {
    var handler = webSocketHandler((webSocket) {
      event.onNewClient((bool ok, ISocketEvent e){
        if(ok) {
          // _clientMap[]
        }
      } as (bool, ISocketEvent));

      print("new client");
      webSocket.stream.listen((message) {
        print("$message");
        webSocket.sink.add("echo $message");
      });
    });

    shelf_io.serve(handler, '0.0.0.0', 4567, shared: true).then((server) {
    var host = "${server.address.host}:${server.port}";
    print('Serving at ws://$host');
    event.onListen(host);
    });
  }
}

// 身份验证中间件
  shelf.Handler authenticationMiddleware(shelf.Handler innerHandler) {
    return (shelf.Request request) {
      // 在这里添加你的身份验证逻辑
      var isValid = request.headers['Authorization'] == 'Bearer YourToken';

      if (!isValid) {
        return shelf.Response.forbidden('Authentication failed');
      }

      return innerHandler(request);
    };
  }