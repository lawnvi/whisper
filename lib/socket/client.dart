import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:path_provider/path_provider.dart';

import 'helper.dart';

class SocketClientManager {
  late Socket socket;
  IOSink? sink;

  Future<void> connectToServer(String host, var callback) async {
    try {
      socket = await Socket.connect(host, 4567);
      socket.listen((List<int> data) {
        try {
          String message = utf8.decode(data);
          print('Received data: $message}');
          if (sink == null && message.startsWith("____start_file_stream")) {
            prepareRecvFile(message.substring(22));
          }
          // 处理接收到的数据
          if (sink == null) {
            callback(message);
          }
        }catch(e) {
          print("recv decode err: $e");
        }

        if (sink != null) {
          sink?.add(data);
        }
      }, onError: (error) {
        print('Error: $error');
        socket.destroy();
      }, onDone: () {
        print('Server disconnected');
        socket.destroy();
      });
    }catch (e) {
      print("请求连接 $host错误: $e");
    }
  }

  void sendMessage(String message) {
    socket.add(utf8.encode(message));
  }

  void prepareRecvFile(String name) async {
    var appDir = await getApplicationDocumentsDirectory();
    File file = File('${appDir.path}/$name');
    sink = file.openWrite();
    print("prepare recv: ${appDir.path}/$name");
  }

  void closeFile() {
    sink?.close();
    sink = null;
  }

  void sendFile(String path) async {
    socketSendFile(socket, path);
  }

  void disconnect() {
    socket.close();
    print('Disconnected from server');
  }
}
